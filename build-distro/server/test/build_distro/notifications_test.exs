defmodule BuildDistro.NotificationsTest do
  use BuildDistroWeb.ConnCase

  alias BuildDistro.{Builds, Notifications, Projects, Repo}
  alias BuildDistro.Notifications.Subscription
  alias BuildDistro.Workers.NotifyBuild
  alias BuildDistroWeb.{Access, Viewer}

  setup do
    configure_push()
    %{project: project} = project_fixture()
    {:ok, link, token} = Projects.create_public_link(project, "main")

    %{
      project: project,
      link: link,
      viewer: Access.public_viewer(project, token),
      push: push_fixture()
    }
  end

  test "a ready transition atomically queues each matching subscription exactly once", ctx do
    %{project: project, viewer: viewer, push: push} = ctx
    {:ok, subscription} = Notifications.subscribe(viewer, "main", push.subscription)
    pr = ready_build(project, %{"pr_number" => 8, "branch" => "feature"})
    refute_enqueued(worker: NotifyBuild, args: %{build_id: pr.id})

    main = ready_build(project)

    assert_enqueued(
      worker: NotifyBuild,
      args: %{build_id: main.id, subscription_id: subscription.id}
    )

    assert {:ok, _} = Builds.mark_ready(main, %{})
    assert [%{args: %{"build_id" => id}}] = all_enqueued(worker: NotifyBuild)
    assert id == main.id
    assert Notifications.subscribed?(viewer, "main", push.subscription["endpoint"])

    refute subscription.encrypted_subscription =~ push.subscription["endpoint"]
    refute subscription.encrypted_subscription =~ push.subscription["keys"]["auth"]
  end

  test "delivers an encrypted install-ready notification with a working public destination",
       ctx do
    {:ok, subscription} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    build = ready_build(ctx.project)
    test_pid = self()

    stub_push(fn request ->
      assert Req.Request.get_header(request, "content-encoding") == ["aes128gcm"]
      assert ["vapid " <> _] = Req.Request.get_header(request, "authorization")
      assert request.options.redirect == false
      payload = decrypt(request.body, ctx.push)
      send(test_pid, {:notification, payload})
      {request, Req.Response.new(status: 201)}
    end)

    assert :ok = perform_job(NotifyBuild, %{build_id: build.id, subscription_id: subscription.id})
    assert_receive {:notification, payload}
    assert payload["title"] == "My App · new build"
    assert payload["body"] =~ "1.4.0 (412) is ready"
    assert payload["url"] =~ "/#{ctx.project.slug}/p/"
    assert payload["url"] =~ "/builds/#{build.number}"
    assert {:ok, _, html} = live(build_conn(), payload["url"])
    assert html =~ "itms-services://"
  end

  test "revocation is checked before delivery, including already queued jobs", ctx do
    {:ok, subscription} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    build = ready_build(ctx.project)
    :ok = Projects.revoke_public_link(ctx.project, ctx.link.id)
    assert :ok = perform_job(NotifyBuild, %{build_id: build.id, subscription_id: subscription.id})
    assert Repo.get(Subscription, subscription.id) == nil
  end

  test "tester and admin access is rechecked before delivery", ctx do
    {:ok, invite, _} = Projects.create_invite(ctx.project, %{"label" => "Tester"})
    tester = Viewer.new(ctx.project, :tester, invite_id: invite.id)
    {:ok, sub} = Notifications.subscribe(tester, "main", ctx.push.subscription)
    build = ready_build(ctx.project)
    :ok = Projects.revoke_invite(ctx.project, invite.id)
    assert {:error, :gone} = Notifications.deliver(build, sub)

    {:ok, user} = BuildDistro.Accounts.sign_in(%{"id" => 4242, "login" => "Admin-Login"})
    admin = Viewer.new(ctx.project, :admin, admin: user)
    {:ok, sub} = Notifications.subscribe(admin, "main", ctx.push.subscription)
    Repo.delete!(user)
    assert {:error, :gone} = Notifications.deliver(build, sub)
  end

  test "expired subscriptions are removed, transient failures retry, and unsubscribe stops queued jobs",
       ctx do
    {:ok, sub} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    build = ready_build(ctx.project)
    args = %{build_id: build.id, subscription_id: sub.id}

    stub_push(fn request -> {request, Req.Response.new(status: 503)} end)
    assert {:error, {:push_status, 503}} = perform_job(NotifyBuild, args)
    assert Repo.get(Subscription, sub.id)
    stub_push(fn request -> {request, Req.Response.new(status: 410)} end)
    assert :ok = perform_job(NotifyBuild, args)
    refute Repo.get(Subscription, sub.id)

    {:ok, sub} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    :ok = Notifications.unsubscribe(ctx.viewer, "main", ctx.push.subscription["endpoint"])
    assert :ok = perform_job(NotifyBuild, %{build_id: build.id, subscription_id: sub.id})
  end

  test "subscription retries upsert without duplicates and another grant cannot delete them",
       ctx do
    assert {:ok, _} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    assert {:ok, _} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    assert [_] = Repo.all(Subscription)

    {:ok, _link, token} = Projects.create_public_link(ctx.project, "main")
    other = Access.public_viewer(ctx.project, token)
    refute Notifications.subscribed?(other, "main", ctx.push.subscription["endpoint"])
    :ok = Notifications.unsubscribe(other, "main", ctx.push.subscription["endpoint"])
    assert Notifications.subscribed?(ctx.viewer, "main", ctx.push.subscription["endpoint"])
  end

  test "rejects arbitrary destinations and malformed keys", ctx do
    for endpoint <- [
          "http://web.push.apple.com/x",
          "https://127.0.0.1/x",
          "https://web.push.apple.com.evil.test/x",
          "https://web.push.apple.com:444/x",
          "https://user@web.push.apple.com/x"
        ] do
      params = Map.put(ctx.push.subscription, "endpoint", endpoint)
      assert {:error, _} = Notifications.subscribe(ctx.viewer, "main", params)
    end

    assert {:error, _} =
             Notifications.subscribe(
               ctx.viewer,
               "main",
               put_in(ctx.push.subscription, ["keys", "p256dh"], "invalid")
             )

    assert {:error, _} = Notifications.subscribe(ctx.viewer, "main", %{})
    assert {:error, _} = Notifications.subscribe(ctx.viewer, "manual", ctx.push.subscription)
  end

  test "disabled push creates no subscriptions or jobs", ctx do
    Application.delete_env(:web_push, :vapid)
    assert {:error, _} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    ready_build(ctx.project)
    refute_enqueued(worker: NotifyBuild)
  end

  test "subscribing does not notify about existing builds; expired builds do not send", ctx do
    build = ready_build(ctx.project)
    {:ok, sub} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    refute_enqueued(worker: NotifyBuild)
    {:ok, _} = Builds.expire(build)
    assert :ok = perform_job(NotifyBuild, %{build_id: build.id, subscription_id: sub.id})
  end

  test "deliveries cannot cross projects or buckets", ctx do
    {:ok, sub} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)
    %{project: other} = project_fixture()
    assert {:error, :gone} = Notifications.deliver(ready_build(other), sub)

    assert {:error, :gone} =
             Notifications.deliver(ready_build(ctx.project, %{"branch" => "experiment"}), sub)
  end

  test "long build metadata stays within the push service payload limit", ctx do
    {:ok, sub} = Notifications.subscribe(ctx.viewer, "main", ctx.push.subscription)

    {:ok, project} =
      Projects.update_project(ctx.project, %{"name" => String.duplicate("App ", 1000)})

    build = ready_build(project)

    build = %{
      build
      | version: String.duplicate("1", 10000),
        build_version: String.duplicate("2", 10000)
    }

    stub_push(fn request ->
      payload = decrypt(request.body, ctx.push)
      assert byte_size(Jason.encode!(payload)) < 4000
      assert String.length(payload["title"]) < 100
      {request, Req.Response.new(status: 201)}
    end)

    assert :ok = Notifications.deliver(build, sub)
  end

  defp stub_push(adapter), do: Process.put(:push_adapter, adapter)

  # Receive side of RFC 8291/8188, independent of the sender's encryption implementation.
  defp decrypt(<<salt::binary-size(16), _record_size::32, size, rest::binary>>, push) do
    <<server_public::binary-size(^size), encrypted::binary>> = rest
    shared = :crypto.compute_key(:ecdh, server_public, push.private, :prime256v1)
    prk_key = :crypto.mac(:hmac, :sha256, push.auth, shared)

    ikm =
      :crypto.mac(
        :hmac,
        :sha256,
        prk_key,
        "WebPush: info" <> <<0>> <> push.public <> server_public <> <<1>>
      )

    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    key =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
      |> binary_part(0, 16)

    nonce =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>)
      |> binary_part(0, 12)

    length = byte_size(encrypted) - 16
    <<cipher::binary-size(^length), tag::binary-size(16)>> = encrypted
    plain = :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, cipher, <<>>, tag, false)
    assert :binary.last(plain) == 2
    plain |> binary_part(0, byte_size(plain) - 1) |> Jason.decode!()
  end
end
