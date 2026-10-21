defmodule BuildDistroWeb.Api.BuildController do
  @moduledoc """
  The CI upload protocol. Every action is idempotent; see ARCHITECTURE.md.
  """

  use BuildDistroWeb, :controller

  alias BuildDistro.Builds
  alias BuildDistro.Builds.{Artifact, Build}

  action_fallback BuildDistroWeb.Api.FallbackController

  def create(conn, params) do
    with {:ok, build} <- Builds.start_upload(conn.assigns.project, params) do
      json(conn, build_json(conn, build))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, build} <- fetch_build(conn, id), do: json(conn, build_json(conn, build))
  end

  def parts(conn, %{"id" => id, "kind" => kind} = params) do
    with {:ok, build} <- fetch_build(conn, id),
         {:ok, result} <- Builds.part_urls(build, kind, params["part_numbers"] || []) do
      json(conn, %{
        uploaded: result.uploaded,
        urls: Map.new(result.urls, fn {number, url} -> {Integer.to_string(number), url} end),
        part_size: result.part_size,
        part_count: result.part_count
      })
    end
  end

  def progress(conn, %{"id" => id, "kind" => kind} = params) do
    with {:ok, build} <- fetch_build(conn, id),
         :ok <- Builds.report_part(build, kind, params["part_number"], params["size"]) do
      send_resp(conn, :no_content, "")
    end
  end

  def complete(conn, %{"id" => id}) do
    with {:ok, build} <- fetch_build(conn, id),
         {:ok, build} <- Builds.complete(build) do
      json(conn, build_json(conn, build))
    end
  end

  defp fetch_build(conn, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Build{} = build <- Builds.get_project_build(conn.assigns.project, id) do
      {:ok, build}
    else
      _ -> {:error, :not_found}
    end
  end

  defp build_json(conn, build) do
    project = conn.assigns.project

    %{
      id: build.id,
      number: build.number,
      state: build.state,
      url: BuildDistroWeb.Links.build_url(project, build),
      failure_reason: build.failure_reason,
      display_name: build.display_name,
      version: build.version,
      build_version: build.build_version,
      artifacts:
        Enum.map(build.artifacts, fn artifact ->
          %{
            kind: artifact.kind,
            size: artifact.size,
            part_size: artifact.part_size,
            part_count: Artifact.part_count(artifact),
            uploaded: artifact.uploaded_at != nil
          }
        end)
    }
  end
end
