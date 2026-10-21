defmodule BuildDistroWeb.Viewer do
  @moduledoc """
  What the current visitor may see of a project and where its pages live:
  admins and testers see every bucket under `/:project`; a public link sees
  one bucket under `/:project/p/:token`, without signing in.
  """

  alias BuildDistro.Builds.Build

  defstruct [:project, :kind, :admin, :buckets, :base]

  def new(project, kind, opts \\ [])

  def new(project, :public, opts) do
    %__MODULE__{
      project: project,
      kind: :public,
      buckets: [Keyword.fetch!(opts, :bucket)],
      base: "/#{project.slug}/p/#{Keyword.fetch!(opts, :token)}"
    }
  end

  def new(project, kind, opts) do
    %__MODULE__{
      project: project,
      kind: kind,
      admin: opts[:admin],
      buckets: Build.buckets(),
      base: "/#{project.slug}"
    }
  end

  def can_see?(%__MODULE__{buckets: buckets}, %Build{bucket: bucket}), do: bucket in buckets

  def home_path(viewer), do: viewer.base
  def bucket_path(viewer, bucket), do: "#{viewer.base}?bucket=#{bucket}"
  def build_path(viewer, build), do: "#{viewer.base}/builds/#{build.number}"
  def icon_path(viewer, build), do: "#{viewer.base}/builds/#{build.number}/icon.png"

  @doc "dSYM and IPA downloads are for admins and testers, not public links."
  def downloads?(%__MODULE__{kind: kind}), do: kind != :public
end
