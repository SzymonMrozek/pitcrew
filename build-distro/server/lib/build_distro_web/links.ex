defmodule BuildDistroWeb.Links do
  @moduledoc "Absolute URLs for places outside the web layer: the API and invites."

  use BuildDistroWeb, :verified_routes

  def build_url(project, build), do: url(~p"/#{project.slug}/builds/#{build.number}")

  def invite_url(project, token), do: url(~p"/#{project.slug}/join/#{token}")
end
