defmodule BuildDistro.PublicLinksTest do
  use BuildDistro.DataCase

  alias BuildDistro.Projects

  test "copied tokens are scoped to their project and reject tampering" do
    %{project: project} = project_fixture()
    %{project: other_project} = project_fixture(%{"slug" => "other"})
    {:ok, link, token} = Projects.create_public_link(project, "main")

    assert Projects.find_active_public_link(project, token).id == link.id
    assert Projects.find_active_public_link(other_project, token) == nil
    assert Projects.find_active_public_link(project, token <> "tampered") == nil

    wrong_salt = Phoenix.Token.sign(BuildDistroWeb.Endpoint, "install", link.token_hash)
    assert Projects.find_active_public_link(project, wrong_salt) == nil
  end
end
