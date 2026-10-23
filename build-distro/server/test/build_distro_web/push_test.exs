defmodule BuildDistroWeb.PushTest do
  use BuildDistroWeb.ConnCase

  alias BuildDistro.Projects

  setup do
    configure_push()
    %{project: project} = project_fixture()
    BuildDistro.RateLimiter.reset({:push, project.id, "127.0.0.1"})
    on_exit(fn -> BuildDistro.RateLimiter.reset({:push, project.id, "127.0.0.1"}) end)
    {:ok, link, token} = Projects.create_public_link(project, "main")
    %{project: project, link: link, token: token, push: push_fixture()}
  end

  test "anonymous public visitors can opt in only to their bucket and opt out", ctx do
    path = ~p"/#{ctx.project.slug}/p/#{ctx.token}/notifications/main"
    assert post_json(path, "status", ctx.push.subscription)["subscribed"] == false
    assert post_json(path, "subscribe", ctx.push.subscription)["subscribed"] == true
    assert post_json(path, "status", ctx.push.subscription)["subscribed"] == true
    assert post_json(path, "unsubscribe", ctx.push.subscription)["subscribed"] == false

    assert build_conn()
           |> post(~p"/#{ctx.project.slug}/p/#{ctx.token}/notifications/manual", %{
             "action" => "subscribe"
           })
           |> response(404)

    assert build_conn()
           |> post(~p"/#{ctx.project.slug}/notifications/main", %{"action" => "subscribe"})
           |> response(404)

    :ok = Projects.revoke_public_link(ctx.project, ctx.link.id)
    assert build_conn() |> post(path, %{"action" => "status"}) |> response(404)
  end

  test "testers and admins can opt in to each bucket", ctx do
    for conn <- [join(build_conn(), ctx.project), sign_in_admin(build_conn())],
        bucket <- ~w(main manual pull_requests) do
      conn =
        post(conn, ~p"/#{ctx.project.slug}/notifications/#{bucket}", %{
          "action" => "subscribe",
          "subscription" => ctx.push.subscription
        })

      assert json_response(conn, 200)["subscribed"]
    end
  end

  test "PWA launch preserves the public grant and selected bucket", ctx do
    path = ~p"/#{ctx.project.slug}/p/#{ctx.token}/manifest.webmanifest?bucket=manual"
    conn = build_conn() |> put_req_header("accept", "application/manifest+json") |> get(path)
    assert get_resp_header(conn, "content-type") == ["application/manifest+json; charset=utf-8"]
    manifest = conn |> response(200) |> Jason.decode!()
    assert manifest["start_url"] == ~p"/#{ctx.project.slug}/p/#{ctx.token}?bucket=main"
    assert manifest["display"] == "standalone"
    assert {:ok, _, html} = live(build_conn(), manifest["start_url"])
    assert html =~ "New build notifications"
    assert html =~ "data-public-key"
    assert html =~ "manifest.webmanifest"
    assert html =~ ~s(crossorigin="use-credentials")

    private =
      join(build_conn(), ctx.project)
      |> get(~p"/#{ctx.project.slug}/manifest.webmanifest?bucket=pull_requests")
      |> response(200)
      |> Jason.decode!()

    assert private["start_url"] == ~p"/#{ctx.project.slug}?bucket=pull_requests"

    :ok = Projects.revoke_public_link(ctx.project, ctx.link.id)
    assert build_conn() |> get(path) |> response(404)
  end

  test "testers can open their invite inside a fresh Home Screen session", ctx do
    {:ok, _, token} = Projects.create_invite(ctx.project, %{"label" => "Home Screen"})
    path = ~p"/#{ctx.project.slug}/join/#{token}"
    url = BuildDistroWeb.Endpoint.url() <> path
    assert build_conn() |> get("/") |> html_response(200) =~ "Open your invite"
    conn = build_conn() |> post("/auth/invite", %{"invite_url" => url})
    assert redirected_to(conn) == path
    conn = conn |> recycle() |> post(path, %{"passcode" => "secret-passcode"})
    assert {:ok, _, html} = conn |> recycle() |> live(~p"/#{ctx.project.slug}")
    assert html =~ "New build notifications"

    for url <- [
          "https://evil.example#{path}",
          "javascript:alert(1)",
          "//evil.example/path",
          "http://localhost/other"
        ] do
      conn = build_conn() |> post("/auth/invite", %{"invite_url" => url})
      assert redirected_to(conn) == "/"
    end
  end

  test "service worker and install icons are available without authentication" do
    assert build_conn() |> get("/service-worker.js") |> response(200) =~ "notificationclick"

    for size <- [192, 512] do
      assert build_conn() |> get("/images/pwa-#{size}.png") |> response(200) =~ "PNG"
    end
  end

  test "public access cannot be reused for another project or without CSRF protection", ctx do
    %{project: other} = project_fixture()
    path = ~p"/#{other.slug}/p/#{ctx.token}/notifications/main"
    assert build_conn() |> post(path, %{"action" => "subscribe"}) |> response(404)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      build_conn()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/#{ctx.project.slug}/p/#{ctx.token}/notifications/main", %{
        "action" => "subscribe"
      })
    end
  end

  test "subscription registration is rate limited while opt-out remains available", ctx do
    path = ~p"/#{ctx.project.slug}/p/#{ctx.token}/notifications/main"

    for _ <- 1..30 do
      assert post_json(path, "subscribe", ctx.push.subscription)["subscribed"]
    end

    conn =
      build_conn()
      |> post(path, %{"action" => "subscribe", "subscription" => ctx.push.subscription})

    assert json_response(conn, 429)
    assert post_json(path, "unsubscribe", ctx.push.subscription)["subscribed"] == false
  end

  defp post_json(path, action, subscription) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(%{action: action, subscription: subscription}))
    |> json_response(200)
  end
end
