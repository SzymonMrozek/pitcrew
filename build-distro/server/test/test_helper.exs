case BuildDistro.Storage.ensure_bucket() do
  :ok ->
    :ok

  {:error, reason} ->
    raise """
    The S3 test server isn't reachable (#{inspect(reason)}). Start it with:

        docker compose -f test/s3/compose.yaml up -d --wait
    """
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(BuildDistro.Repo, :manual)
