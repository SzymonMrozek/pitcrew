defmodule BuildDistroWeb.Links do
  @moduledoc "Absolute URLs for sharing builds, the API and invites."

  use BuildDistroWeb, :verified_routes

  alias BuildDistro.Projects

  def build_url(project, build),
    do: public_build_url(project, build) || url(~p"/#{project.slug}/builds/#{build.number}")

  def public_build_url(project, build) do
    case Projects.public_link_for_bucket(project, build.bucket) do
      nil ->
        nil

      link ->
        url(~p"/#{project.slug}/p/#{Projects.public_link_token(link)}/builds/#{build.number}")
    end
  end

  def invite_url(project, token), do: url(~p"/#{project.slug}/join/#{token}")
end
