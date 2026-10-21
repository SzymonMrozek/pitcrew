defmodule BuildDistroWeb.Api.FallbackController do
  use BuildDistroWeb, :controller

  def call(conn, {:error, :not_found}), do: error(conn, 404, %{error: "not found"})

  def call(conn, {:error, :expired}),
    do: error(conn, 409, %{error: "this build expired; use a new idempotency key"})

  def call(conn, {:error, {:state, state}}),
    do: error(conn, 409, %{error: "the build is #{state}", state: state})

  def call(conn, {:error, {:incomplete, kind, missing}}),
    do: error(conn, 409, %{error: "parts are missing", kind: kind, missing_parts: missing})

  def call(conn, {:error, {:invalid, field, message}}),
    do: error(conn, 422, %{error: "#{field} #{message}"})

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    error(conn, 422, %{error: "invalid build", fields: errors})
  end

  # Bucket and network failures are worth retrying.
  def call(conn, {:error, _reason}), do: error(conn, 503, %{error: "storage unavailable, retry"})

  defp error(conn, status, body), do: conn |> put_status(status) |> json(body)
end
