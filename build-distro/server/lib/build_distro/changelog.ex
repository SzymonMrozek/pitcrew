defmodule BuildDistro.Changelog do
  @moduledoc """
  What changed in a build. CI sends the commits from GitHub's compare API:
  for a pull request, what it adds to the main branch; for main, everything
  since the previous ready build on main.

  Commits are stored as sent and grouped when shown, so editing a project's
  tooling rules regroups every build. Conventional Commits whose type or
  scope marks tooling go last, apart from the app changes testers look for.
  """

  alias BuildDistro.Builds.Build
  alias BuildDistro.Projects.Project
  alias BuildDistro.Repo

  @default_tooling_types ~w(chore ci build refactor style test docs)
  @default_tooling_scopes ~w(tooling review deps modules dev-menu)
  @max_commits 1_000
  @conventional ~r/^(?<type>[a-zA-Z]+)(?:\((?<scope>[^)]*)\))?(?<breaking>!)?:\s*(?<subject>.+)$/

  def default_tooling_types, do: Enum.join(@default_tooling_types, ", ")
  def default_tooling_scopes, do: Enum.join(@default_tooling_scopes, ", ")

  @doc """
  Stores a build's changelog, replacing any earlier one, so CI can send it
  again safely. `params`: `base` (the commit it starts after, absent for a
  first build), `head`, `kind` and `commits` (`sha`, `message`, `author`).
  """
  def put(%Build{} = build, params) when is_map(params) do
    with {:ok, commits} <- commits(params["commits"]),
         {:ok, kind} <- kind(params["kind"]) do
      changelog = %{
        "kind" => kind,
        "base" => sha(params["base"]),
        "head" => sha(params["head"]) || build.commit_sha,
        "commits" => Enum.take(commits, @max_commits),
        "truncated" => length(commits) > @max_commits or params["truncated"] == true
      }

      build |> Ecto.Changeset.change(changelog: changelog) |> Repo.update()
    end
  end

  def put(_build, _params), do: {:error, {:invalid, "changelog", "must be an object"}}

  defp kind(kind) when kind in ~w(pull_request main first branch), do: {:ok, kind}
  defp kind(_), do: {:error, {:invalid, "kind", "must be pull_request, main, first or branch"}}

  defp commits(commits) when is_list(commits) do
    Enum.reduce_while(commits, {:ok, []}, fn
      %{"sha" => sha, "message" => message} = commit, {:ok, acc} when is_binary(message) ->
        case sha(sha) do
          nil ->
            {:halt, {:error, {:invalid, "commits", "need a commit SHA"}}}

          sha ->
            author = if is_binary(commit["author"]), do: String.slice(commit["author"], 0, 100)

            {:cont,
             {:ok,
              [
                %{"sha" => sha, "message" => String.slice(message, 0, 2_000), "author" => author}
                | acc
              ]}}
        end

      _, _ ->
        {:halt, {:error, {:invalid, "commits", "each needs a sha and a message"}}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp commits(_), do: {:error, {:invalid, "commits", "must be a list"}}

  defp sha(sha) when is_binary(sha) do
    sha = String.downcase(sha)
    if Regex.match?(~r/^[0-9a-f]{7,64}$/, sha), do: sha
  end

  defp sha(_), do: nil

  ## Showing

  @doc """
  The build's changes, app changes first and tooling last, or nil when CI
  sent none.
  """
  def grouped(%Build{changelog: %{"commits" => commits} = changelog}, %Project{} = project) do
    rules = rules(project)
    entries = Enum.map(commits, &entry/1)
    {tooling, app} = Enum.split_with(entries, &tooling?(&1, rules))

    %{
      kind: changelog["kind"],
      base: changelog["base"],
      head: changelog["head"],
      truncated: changelog["truncated"] == true,
      app: app,
      tooling: tooling
    }
  end

  def grouped(_build, _project), do: nil

  @doc "Splits a commit message into its Conventional Commit parts."
  def entry(%{"sha" => sha, "message" => message} = commit) do
    [first | rest] = String.split(message, "\n", parts: 2)
    first = String.trim(first)

    base = %{sha: sha, author: commit["author"], body: rest |> List.first() |> blank_to_nil()}

    case Regex.named_captures(@conventional, first) do
      %{"type" => type, "scope" => scope, "breaking" => breaking, "subject" => subject} ->
        Map.merge(base, %{
          type: String.downcase(type),
          scope: blank_to_nil(String.downcase(scope)),
          breaking: breaking == "!",
          subject: subject
        })

      nil ->
        Map.merge(base, %{type: nil, scope: nil, breaking: false, subject: first})
    end
  end

  def tooling?(%{type: type, scope: scope}, %{types: types, scopes: scopes}) do
    type in types or (scope != nil and scope in scopes)
  end

  def rules(%Project{} = project) do
    %{
      types: list(project.tooling_types, @default_tooling_types),
      scopes: list(project.tooling_scopes, @default_tooling_scopes)
    }
  end

  defp list(nil, default), do: default

  defp list(text, _default) do
    text |> String.split(~r/[,\s]+/, trim: true) |> Enum.map(&String.downcase/1)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
