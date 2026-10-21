defmodule BuildDistroWeb.ConnCase do
  @moduledoc "Tests that go through the router."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BuildDistroWeb.Endpoint

      use BuildDistroWeb, :verified_routes
      use Oban.Testing, repo: BuildDistro.Repo, engine: Oban.Engines.Lite

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import BuildDistroWeb.ConnCase
      import BuildDistro.Fixtures

      alias BuildDistro.Repo
    end
  end

  setup tags do
    BuildDistro.DataCase.setup_sandbox(tags)

    on_exit(fn ->
      BuildDistro.RateLimiter.reset({:join, "127.0.0.1"})
      BuildDistro.RateLimiter.reset({:admin, "127.0.0.1"})
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "A browser that accepted an invite to `project`."
  def join(conn, project) do
    {:ok, _invite, token} = BuildDistro.Projects.create_invite(project, %{"label" => "Tester"})

    conn
    |> Phoenix.ConnTest.dispatch(
      BuildDistroWeb.Endpoint,
      :post,
      "/#{project.slug}/join/#{token}",
      %{
        "passcode" => "secret-passcode"
      }
    )
    |> Phoenix.ConnTest.recycle()
  end
end
