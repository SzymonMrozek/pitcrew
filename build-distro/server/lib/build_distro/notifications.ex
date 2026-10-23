defmodule BuildDistro.Notifications do
  @moduledoc "Opt-in Web Push per bucket, authorized again before every delivery."

  import Ecto.Query

  alias BuildDistro.{Accounts, Projects, Repo, Secrets}
  alias BuildDistro.Notifications.Subscription
  alias BuildDistro.Projects.PublicLink
  alias BuildDistroWeb.{Endpoint, Viewer}

  def public_key, do: Application.get_env(:web_push, :vapid, [])[:public_key]
  def enabled?, do: is_binary(public_key()) and public_key() != ""

  def subscribed?(viewer, bucket, endpoint) when is_binary(endpoint) do
    case Repo.one(query(viewer, bucket, endpoint)) do
      nil -> false
      subscription -> same_grant?(subscription, grant(viewer))
    end
  end

  def subscribed?(_, _, _), do: false

  def subscribe(viewer, bucket, params) do
    with true <- enabled?(),
         true <- bucket in viewer.buckets,
         {:ok, subscription} <- validate(params) do
      now = DateTime.utc_now()

      attrs =
        Map.merge(grant(viewer), %{
          project_id: viewer.project.id,
          bucket: bucket,
          endpoint_hash: Secrets.hash_token(subscription["endpoint"]),
          encrypted_subscription:
            Phoenix.Token.encrypt(Endpoint, "push-subscription", subscription),
          updated_at: now
        })

      %Subscription{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:encrypted_subscription, :user_id, :invite_id, :public_link_id, :updated_at]},
        conflict_target: [:project_id, :bucket, :endpoint_hash]
      )
    else
      _ -> {:error, :invalid_subscription}
    end
  end

  def unsubscribe(viewer, bucket, endpoint) when is_binary(endpoint) do
    case Repo.one(query(viewer, bucket, endpoint)) do
      nil ->
        :ok

      subscription ->
        if same_grant?(subscription, grant(viewer)), do: Repo.delete!(subscription)
        :ok
    end
  end

  def unsubscribe(_, _, _), do: :ok

  # Called inside the ready transition, so a restart cannot lose the notification jobs.
  def enqueue(build) do
    if enabled?() do
      for subscription <-
            Repo.all(
              from s in Subscription,
                where: s.project_id == ^build.project_id and s.bucket == ^build.bucket
            ) do
        %{build_id: build.id, subscription_id: subscription.id}
        |> BuildDistro.Workers.NotifyBuild.new()
        |> Oban.insert!()
      end
    end

    :ok
  end

  def deliver(build, subscription) do
    with true <-
           build.project_id == subscription.project_id and build.bucket == subscription.bucket,
         %Viewer{} = viewer <- viewer(subscription),
         true <- Viewer.can_see?(viewer, build),
         {:ok, data} <-
           Phoenix.Token.decrypt(
             Endpoint,
             "push-subscription",
             subscription.encrypted_subscription,
             max_age: :infinity
           ),
         {:ok, data} <- validate(data) do
      payload = %{
        title: "#{String.slice(viewer.project.name, 0, 80)} · new build",
        body:
          "#{String.slice(build.version || "Build", 0, 40)} (#{String.slice(build.build_version || to_string(build.number), 0, 40)}) is ready · #{BuildDistro.Builds.Build.bucket_label(build.bucket)}",
        url: Viewer.build_path(viewer, build),
        tag: "build-#{build.id}",
        icon: "/images/apple-touch-icon.png"
      }

      send_push(data, payload)
    else
      _ -> {:error, :gone}
    end
  end

  defp send_push(data, payload) do
    endpoint = data["endpoint"]
    keys = data["keys"]
    body = WebPush.Encryption.encrypt(Jason.encode!(payload), keys["p256dh"], keys["auth"])

    options = [
      url: endpoint,
      body: body,
      headers: [
        {"authorization", WebPush.Vapid.authorization_header(endpoint)},
        {"content-type", "application/octet-stream"},
        {"content-encoding", "aes128gcm"},
        {"ttl", "86400"},
        {"urgency", "normal"},
        {"topic", payload.tag}
      ],
      redirect: false,
      retry: false,
      receive_timeout: 15_000
    ]

    case Req.post(
           Keyword.merge(options, Application.get_env(:build_distro, :push_request_options, []))
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [404, 410] -> {:error, :gone}
      {:ok, %{status: status}} -> {:error, {:push_status, status}}
      {:error, _} -> {:error, :push_unavailable}
    end
  end

  defp viewer(subscription) do
    project = Projects.get_project!(subscription.project_id)

    cond do
      subscription.user_id ->
        if user = Accounts.get_admin(subscription.user_id),
          do: Viewer.new(project, :admin, admin: user)

      subscription.invite_id ->
        if Projects.invite_active?(project, subscription.invite_id),
          do: Viewer.new(project, :tester, invite_id: subscription.invite_id)

      subscription.public_link_id ->
        case Repo.get(PublicLink, subscription.public_link_id) do
          %PublicLink{revoked_at: nil, project_id: id, bucket: bucket} = link
          when id == project.id and bucket == subscription.bucket ->
            Viewer.new(project, :public,
              bucket: bucket,
              token: Projects.public_link_token(link),
              public_link_id: link.id
            )

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp grant(%Viewer{kind: :admin, admin: user}),
    do: %{user_id: user.id, invite_id: nil, public_link_id: nil}

  defp grant(%Viewer{kind: :tester, invite_id: id}),
    do: %{user_id: nil, invite_id: id, public_link_id: nil}

  defp grant(%Viewer{kind: :public, public_link_id: id}),
    do: %{user_id: nil, invite_id: nil, public_link_id: id}

  defp same_grant?(subscription, grant),
    do: Enum.all?(grant, fn {key, value} -> Map.get(subscription, key) == value end)

  defp query(viewer, bucket, endpoint) do
    hash = Secrets.hash_token(endpoint)

    from s in Subscription,
      where:
        s.project_id == ^viewer.project.id and s.bucket == ^bucket and s.endpoint_hash == ^hash
  end

  defp validate(%{"endpoint" => endpoint, "keys" => %{"p256dh" => key, "auth" => auth}})
       when is_binary(endpoint) and byte_size(endpoint) <= 2048 and is_binary(key) and
              byte_size(key) <= 100 and is_binary(auth) and byte_size(auth) <= 24 do
    uri = URI.parse(endpoint)

    with true <-
           uri.scheme == "https" and uri.port == 443 and is_nil(uri.userinfo) and
             is_nil(uri.fragment),
         true <- allowed_host?(uri.host),
         {:ok, <<4, _::binary-size(64)>> = public} <- Base.url_decode64(key, padding: false),
         {:ok, secret} when byte_size(secret) == 16 <- Base.url_decode64(auth, padding: false) do
      # Reject malformed curve points now, before a durable job reaches encryption.
      {_, private} = :crypto.generate_key(:ecdh, :prime256v1)
      :crypto.compute_key(:ecdh, public, private, :prime256v1)
      {:ok, %{"endpoint" => endpoint, "keys" => %{"p256dh" => key, "auth" => auth}}}
    else
      _ -> {:error, :invalid_subscription}
    end
  rescue
    _ -> {:error, :invalid_subscription}
  end

  defp validate(_), do: {:error, :invalid_subscription}

  # Subscriptions are supplied by browsers: never turn them into arbitrary server-side requests.
  defp allowed_host?(host) when is_binary(host) do
    host in ["fcm.googleapis.com", "updates.push.services.mozilla.com"] or
      String.ends_with?(host, ".push.apple.com") or String.ends_with?(host, ".notify.windows.com")
  end

  defp allowed_host?(_), do: false
end
