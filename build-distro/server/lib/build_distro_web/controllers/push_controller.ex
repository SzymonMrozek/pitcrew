defmodule BuildDistroWeb.PushController do
  use BuildDistroWeb, :controller

  alias BuildDistro.Notifications

  def update(conn, %{"bucket" => bucket, "action" => action} = params) do
    viewer = conn.assigns.viewer
    subscription = params["subscription"] || %{}

    if bucket in viewer.buckets and is_map(subscription) do
      case action do
        "status" ->
          json(conn, %{
            subscribed: Notifications.subscribed?(viewer, bucket, subscription["endpoint"])
          })

        "subscribe" ->
          ip = BuildDistroWeb.JoinController.client_ip(conn)

          if BuildDistro.RateLimiter.hit({:push, viewer.project.id, ip}, 30, :timer.minutes(10)) ==
               :error do
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "Too many attempts. Try again later."})
          else
            case Notifications.subscribe(viewer, bucket, subscription) do
              {:ok, _} ->
                json(conn, %{subscribed: true})

              {:error, _} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Cannot enable notifications."})
            end
          end

        "unsubscribe" ->
          :ok = Notifications.unsubscribe(viewer, bucket, subscription["endpoint"])
          json(conn, %{subscribed: false})

        _ ->
          invalid(conn)
      end
    else
      invalid(conn)
    end
  end

  def update(conn, _), do: invalid(conn)

  defp invalid(conn), do: conn |> put_status(:not_found) |> json(%{error: "Not found"})
end
