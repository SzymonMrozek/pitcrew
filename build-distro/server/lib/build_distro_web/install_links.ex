defmodule BuildDistroWeb.InstallLinks do
  @moduledoc """
  Links iOS follows without cookies. The manifest URL carries a signed token
  that names the build and expires; the manifest it serves points at a
  presigned IPA URL created at that moment.
  """

  use BuildDistroWeb, :verified_routes

  @salt "install"
  @max_age 3_600

  def install_url(build) do
    manifest = url(~p"/i/#{token(build)}/manifest.plist")
    "itms-services://?action=download-manifest&url=" <> URI.encode_www_form(manifest)
  end

  def icon_url(build), do: url(~p"/i/#{token(build)}/icon.png")

  def max_age, do: @max_age

  def verify(token) do
    Phoenix.Token.verify(BuildDistroWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  defp token(build), do: Phoenix.Token.sign(BuildDistroWeb.Endpoint, @salt, build.id)
end
