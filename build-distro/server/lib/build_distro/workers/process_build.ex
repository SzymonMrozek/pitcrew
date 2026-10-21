defmodule BuildDistro.Workers.ProcessBuild do
  @moduledoc "Reads an uploaded IPA and makes the build ready."

  use Oban.Worker,
    queue: :processing,
    max_attempts: 5,
    unique: [keys: [:build_id], states: :incomplete, period: :infinity]

  require Logger

  alias BuildDistro.{Builds, IPA, Storage}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"build_id" => build_id}, attempt: attempt, max_attempts: max}) do
    build = Builds.get_build!(build_id)
    Logger.metadata(build_id: build_id)

    with "processing" <- build.state,
         %{} = ipa <- Builds.artifact(build, "ipa") do
      reader = &Storage.read_range(ipa.object_key, &1, &2)

      case IPA.inspect_ipa(reader, ipa.size) do
        {:ok, metadata} ->
          with {:ok, icon_key} <- store_icon(ipa, metadata.icon),
               {:ok, _} <- Builds.mark_ready(build, Map.put(metadata, :icon_key, icon_key)) do
            :ok
          end

        {:error, {:invalid, reason}} ->
          {:ok, _} = Builds.mark_failed(build, reason)
          {:cancel, reason}

        {:error, reason} when attempt >= max ->
          {:ok, _} = Builds.mark_failed(build, "Processing failed: #{inspect(reason)}")
          {:cancel, reason}

        {:error, reason} ->
          Logger.warning("Processing failed, will retry: #{inspect(reason)}")
          {:error, reason}
      end
    else
      _ -> :ok
    end
  end

  defp store_icon(_ipa, nil), do: {:ok, nil}

  defp store_icon(ipa, png) do
    key = Path.join(Path.dirname(Path.dirname(ipa.object_key)), "icon.png")

    with :ok <- Storage.put(key, png, "image/png"), do: {:ok, key}
  end
end
