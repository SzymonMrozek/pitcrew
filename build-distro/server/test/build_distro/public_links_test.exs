defmodule BuildDistro.PublicLinksTest do
  use BuildDistro.DataCase

  alias BuildDistro.Projects

  test "the default link is stable and belongs to the requested project and bucket" do
    %{project: project} = project_fixture()
    %{project: other} = project_fixture()
    {:ok, _, _} = Projects.create_public_link(other, "main")
    {:ok, _, _} = Projects.create_public_link(project, "manual")
    assert Projects.public_link_for_bucket(project, "main") == nil

    {:ok, first, _} = Projects.create_public_link(project, "main")
    {:ok, second, _} = Projects.create_public_link(project, "main")
    assert Projects.public_link_for_bucket(project, "main").id == first.id

    :ok = Projects.revoke_public_link(project, first.id)
    assert Projects.public_link_for_bucket(project, "main").id == second.id
    :ok = Projects.revoke_public_link(project, second.id)
    assert Projects.public_link_for_bucket(project, "main") == nil
  end

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
