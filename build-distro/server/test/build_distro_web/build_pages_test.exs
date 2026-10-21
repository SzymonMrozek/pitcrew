defmodule BuildDistroWeb.BuildPagesTest do
  use BuildDistroWeb.ConnCase

  alias BuildDistro.Builds
  alias BuildDistro.Workers.ProcessBuild

  setup %{conn: conn} do
    %{project: project} = project_fixture(%{"github_repo" => "example/myapp"})
    %{conn: join(conn, project), project: project}
  end

  test "a page opened during the upload follows it to Install", %{conn: conn, project: project} do
    ipa = ipa_fixture()
    {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))

    {:ok, view, html} = live(conn, ~p"/#{project.slug}/builds/#{build.number}")
    assert html =~ "Uploading from CI"

    :ok = upload_parts(build, "ipa", ipa)
    assert render(view) =~ "Uploading 100%"

    {:ok, _} = Builds.complete(build)
    assert render(view) =~ "Reading the app"

    :ok = perform_job(ProcessBuild, %{build_id: build.id})
    html = render(view)
    assert html =~ "itms-services://?action=download-manifest"
    assert html =~ "My App ✓"
    assert html =~ "1.4.0 (412)"
  end

  test "the list updates live", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/#{project.slug}")
    build = ready_build(project, %{"pr_number" => 42})

    html = render(view)
    assert html =~ "PR #42"
    assert html =~ "Ready"
    assert view |> element("a", "Pull requests") |> render_click() =~ "1.4.0 (412)"
    assert render_patch(view, ~p"/#{project.slug}?filter=other-branch") =~ "No builds yet"
    assert build.number == 1
  end

  test "an older build points at the newer one", %{conn: conn, project: project} do
    old = ready_build(project)
    {:ok, view, html} = live(conn, ~p"/#{project.slug}/builds/#{old.number}")
    refute html =~ "A newer build"

    ready_build(project)
    assert render(view) =~ "A newer build of main is ready"
  end

  test "the manifest serves a presigned IPA URL, escaped for XML", %{conn: conn, project: project} do
    build = ready_build(project)
    {:ok, _view, html} = live(conn, ~p"/#{project.slug}/builds/#{build.number}")

    [_, encoded] = Regex.run(~r/download-manifest&amp;url=([^"]+)"/, html)
    manifest_path = encoded |> URI.decode_www_form() |> URI.parse() |> Map.fetch!(:path)

    xml = build_conn() |> get(manifest_path) |> response(200)
    assert xml =~ "<string>com.example.myapp</string>"

    assert [_, ipa_url] =
             Regex.run(
               ~r{software-package</string>\s*<key>url</key><string>([^<]+)</string>},
               xml
             )

    refute ipa_url =~ ~r/&(?!amp;)/

    ipa_url = String.replace(ipa_url, "&amp;", "&")
    assert %{status: 200, body: <<"PK", _::binary>>} = Req.get!(ipa_url, retry: false)

    icon_path = manifest_path |> String.replace("manifest.plist", "icon.png")
    assert build_conn() |> get(icon_path) |> response(200) =~ "PNG"
  end

  test "install links expire", %{project: project} do
    build = ready_build(project)

    token =
      Phoenix.Token.sign(BuildDistroWeb.Endpoint, "install", build.id,
        signed_at: System.system_time(:second) - 7200
      )

    assert build_conn() |> get(~p"/i/#{token}/manifest.plist") |> response(404) =~ "expired"
  end

  test "downloads and icons need access", %{conn: conn, project: project} do
    build = ready_build(project)

    assert conn
           |> get(~p"/#{project.slug}/builds/#{build.number}/download/ipa")
           |> redirected_to(302) =~ "X-Amz-Signature"

    assert conn |> get(~p"/#{project.slug}/builds/#{build.number}/icon.png") |> response(200) =~
             "PNG"

    assert build_conn()
           |> get(~p"/#{project.slug}/builds/#{build.number}/download/ipa")
           |> response(404)
  end

  test "latest redirects to the newest ready build of a branch", %{conn: conn, project: project} do
    ready_build(project)
    newest = ready_build(project)

    assert conn |> get(~p"/#{project.slug}/latest?branch=main") |> redirected_to() ==
             ~p"/#{project.slug}/builds/#{newest.number}"
  end
end
