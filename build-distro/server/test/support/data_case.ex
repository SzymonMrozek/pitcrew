defmodule BuildDistro.DataCase do
  @moduledoc "Tests that use the database. SQLite allows one writer, so none run async."

  use ExUnit.CaseTemplate

  using do
    quote do
      use Oban.Testing, repo: BuildDistro.Repo, engine: Oban.Engines.Lite

      alias BuildDistro.Repo

      import Ecto.Query
      import BuildDistro.DataCase
      import BuildDistro.Fixtures
    end
  end

  setup tags do
    BuildDistro.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(_tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(BuildDistro.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &BuildDistroWeb.CoreComponents.translate_error/1)
  end
end
