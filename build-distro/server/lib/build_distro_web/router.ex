defmodule BuildDistroWeb.Router do
  use BuildDistroWeb, :router

  import BuildDistroWeb.Access, only: [require_project_access: 2, refresh_session: 2]

  pipeline :browser do
    plug :accepts, ["html", "json", "webmanifest"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BuildDistroWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :refresh_session
  end

  pipeline :project do
    plug :require_project_access
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug BuildDistroWeb.ApiAuth
  end

  get "/health", BuildDistroWeb.HealthController, :show

  scope "/api/v1", BuildDistroWeb.Api do
    pipe_through :api

    post "/builds", BuildController, :create
    get "/builds/:id", BuildController, :show
    post "/builds/:id/artifacts/:kind/parts", BuildController, :parts
    post "/builds/:id/artifacts/:kind/progress", BuildController, :progress
    post "/builds/:id/complete", BuildController, :complete
    put "/builds/:id/changelog", BuildController, :changelog
  end

  # iOS fetches these without cookies; the token in the path authorizes them.
  scope "/i", BuildDistroWeb do
    get "/:token/manifest.plist", InstallController, :manifest
    get "/:token/icon.png", InstallController, :icon
  end

  scope "/", BuildDistroWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/manifest.webmanifest", PwaController, :manifest
    get "/admin/login", AuthController, :new
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    post "/auth/invite", JoinController, :open
    delete "/admin/logout", AuthController, :delete

    if Application.compile_env(:build_distro, :dev_routes) do
      get "/auth/dev", AuthController, :dev
    end

    live_session :admin, on_mount: {BuildDistroWeb.Access, :admin} do
      live "/admin", AdminLive, :index
      live "/admin/projects/:slug", AdminProjectLive, :show
    end

    get "/:project/join/:token", JoinController, :new
    post "/:project/join/:token", JoinController, :create

    scope "/:project" do
      pipe_through :project

      get "/latest", LatestController, :show
      get "/manifest.webmanifest", PwaController, :manifest
      get "/p/:token/manifest.webmanifest", PwaController, :manifest
      post "/notifications/:bucket", PushController, :update
      post "/p/:token/notifications/:bucket", PushController, :update
      get "/builds/:number/download/:kind", DownloadController, :show
      get "/builds/:number/icon.png", DownloadController, :icon
      get "/p/:token/builds/:number/icon.png", DownloadController, :icon
    end

    # A public link shows one bucket to anyone who has it, without signing in.
    live_session :public, on_mount: {BuildDistroWeb.Access, :public} do
      live "/:project/p/:token", BuildsLive, :index
      live "/:project/p/:token/builds/:number", BuildLive, :show
    end

    live_session :project, on_mount: {BuildDistroWeb.Access, :project} do
      live "/:project", BuildsLive, :index
      live "/:project/builds/:number", BuildLive, :show
    end
  end
end
