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

  test "builds are listed by bucket, live", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/#{project.slug}")
    ready_build(project, %{"branch" => "main"})

    assert render(view) =~ "1.4.0 (412)"

    ready_build(project, %{"branch" => "feature/a", "pr_number" => 42})
    ready_build(project, %{"branch" => "feature/a", "pr_number" => 42})
    html = view |> element("a.tab", "Pull requests") |> render_click()
    assert html =~ "PR #42"
    assert html =~ "1 earlier build"

    ready_build(project, %{"branch" => "experiment"})
    assert view |> element("a.tab", "Manual") |> render_click() =~ "experiment"
    assert render(view) =~ ~r/Main\s*<span[^>]*class="tab-count">1</
  end

  test "a public link shows only its bucket, without signing in", %{project: project} do
    main = ready_build(project, %{"branch" => "main"})
    pr = ready_build(project, %{"branch" => "feature/a", "pr_number" => 7})
    {:ok, _link, token} = BuildDistro.Projects.create_public_link(project, "main")
    public = build_conn()

    {:ok, _view, html} = live(public, ~p"/#{project.slug}/p/#{token}")
    assert html =~ "Main builds"
    refute html =~ "PR #7"
    refute html =~ ~s(class="tabs")

    {:ok, _view, html} = live(public, ~p"/#{project.slug}/p/#{token}/builds/#{main.number}")
    assert html =~ "itms-services://"
    refute html =~ "Downloads"

    assert {:error, {:live_redirect, _}} =
             live(public, ~p"/#{project.slug}/p/#{token}/builds/#{pr.number}")

    assert public
           |> get(~p"/#{project.slug}/p/#{token}/builds/#{main.number}/icon.png")
           |> response(200)

    assert public
           |> get(~p"/#{project.slug}/p/#{token}/builds/#{pr.number}/icon.png")
           |> response(404)

    assert public |> get(~p"/#{project.slug}/builds/#{main.number}/download/ipa") |> response(404)
    assert {:error, _} = live(public, ~p"/#{project.slug}")
  end

  test "in-house builds say they install anywhere and how to trust them", %{
    conn: conn,
    project: project
  } do
    ipa = ipa_fixture(profile: profile_fixture(:enterprise))
    build = upload_build(project, [{"ipa", ipa}])
    :ok = perform_job(BuildDistro.Workers.ProcessBuild, %{build_id: build.id})

    {:ok, _view, html} = live(conn, ~p"/#{project.slug}/builds/#{build.number}")
    assert html =~ "In-house"
    assert html =~ "installs on any device"
    assert html =~ "VPN &amp; Device Management"
  end

  test "the changelog lists app changes first and tooling last", %{conn: conn, project: project} do
    build = ready_build(project, %{"branch" => "feature/a", "pr_number" => 9})

    {:ok, _} =
      BuildDistro.Builds.put_changelog(build, %{
        "kind" => "pull_request",
        "base" => "aaaaaaa",
        "head" => build.commit_sha,
        "commits" => [
          %{
            "sha" => "1111111",
            "message" => "chore(tooling): bump the linter",
            "author" => "dev"
          },
          %{"sha" => "2222222", "message" => "feat(trade): add stop orders", "author" => "dev"},
          %{"sha" => "3333333", "message" => "fix(tooling): flaky script"}
        ]
      })

    {:ok, _view, html} = live(conn, ~p"/#{project.slug}/builds/#{build.number}")
    assert html =~ "Changes in this pull request"
    [app, tooling] = String.split(html, "Tooling and internal changes (2)")
    assert app =~ "add stop orders"
    refute app =~ "bump the linter"
    assert tooling =~ "bump the linter"
    assert tooling =~ "flaky script"
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
