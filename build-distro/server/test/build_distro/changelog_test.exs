defmodule BuildDistro.ChangelogTest do
  use BuildDistro.DataCase

  alias BuildDistro.{Builds, Changelog}

  setup do
    %{project: project} = project_fixture()
    %{project: project}
  end

  test "parses Conventional Commits" do
    assert %{type: "feat", scope: "asset-detail", breaking: false, subject: "add funding chart"} =
             Changelog.entry(%{
               "sha" => "abc1234",
               "message" => "feat(asset-detail): add funding chart\n\nBody"
             })

    assert %{type: "fix", scope: nil, breaking: true, subject: "drop iOS 16"} =
             Changelog.entry(%{"sha" => "abc1234", "message" => "fix!: drop iOS 16"})

    assert %{type: nil, subject: "Revert \"feat: x\""} =
             Changelog.entry(%{"sha" => "abc1234", "message" => "Revert \"feat: x\""})
  end

  test "tooling types and scopes go last; project rules replace the defaults", %{project: project} do
    {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", "x"}]))

    commits =
      for {sha, message} <- [
            {"1111111", "feat(trade): stop orders"},
            {"2222222", "chore: bump deps"},
            {"3333333", "fix(tooling): script"},
            {"4444444", "refactor(home): split view"},
            {"5555555", "Plain message"}
          ],
          do: %{"sha" => sha, "message" => message}

    {:ok, build} = Builds.put_changelog(build, %{"kind" => "main", "commits" => commits})
    grouped = Changelog.grouped(build, project)
    assert Enum.map(grouped.app, & &1.sha) == ["1111111", "5555555"]
    assert Enum.map(grouped.tooling, & &1.sha) == ["2222222", "3333333", "4444444"]

    project = %{project | tooling_types: "chore", tooling_scopes: ""}

    assert Enum.map(Changelog.grouped(build, project).app, & &1.sha) == [
             "1111111",
             "3333333",
             "4444444",
             "5555555"
           ]
  end

  test "sending the changelog again replaces it, and bad input is refused", %{project: project} do
    {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", "x"}]))

    {:ok, _} =
      Builds.put_changelog(build, %{
        "kind" => "main",
        "commits" => [%{"sha" => "1111111", "message" => "a"}]
      })

    {:ok, build} =
      Builds.put_changelog(build, %{
        "kind" => "main",
        "commits" => [%{"sha" => "2222222", "message" => "b"}]
      })

    assert [%{"sha" => "2222222"}] = build.changelog["commits"]

    assert {:error, {:invalid, _, _}} =
             Builds.put_changelog(build, %{
               "kind" => "main",
               "commits" => [%{"sha" => "nope", "message" => "a"}]
             })

    assert {:error, {:invalid, _, _}} =
             Builds.put_changelog(build, %{"kind" => "weird", "commits" => []})
  end

  test "builds go to buckets, and main builds know where their changelog starts", %{
    project: project
  } do
    first = ready_build(project, %{"branch" => "main", "commit_sha" => String.duplicate("a", 40)})
    pr = ready_build(project, %{"branch" => "feature", "pr_number" => 3})

    {:ok, manual} =
      Builds.start_upload(project, start_attrs([{"ipa", "x"}], %{"branch" => "experiment"}))

    {:ok, next} = Builds.start_upload(project, start_attrs([{"ipa", "x"}], %{"branch" => "main"}))

    assert {first.bucket, pr.bucket, manual.bucket, next.bucket} ==
             {"main", "pull_requests", "manual", "main"}

    assert Builds.previous_main_commit(first) == nil
    assert Builds.previous_main_commit(next) == String.duplicate("a", 40)
    assert Builds.previous_main_commit(pr) == nil
  end
end
