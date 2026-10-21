defmodule BuildDistro.GitHubOAuth do
  @moduledoc """
  "Sign in with GitHub" through an OAuth App. It requests no scopes: the
  token can only read the public profile, which is all sign-in needs, and it
  is dropped right after.
  """

  def configured?,
    do: config()[:client_id] not in [nil, ""] and config()[:client_secret] not in [nil, ""]

  def authorize_url(state, redirect_uri) do
    query =
      URI.encode_query(%{
        client_id: config()[:client_id],
        redirect_uri: redirect_uri,
        state: state,
        allow_signup: "false"
      })

    "https://github.com/login/oauth/authorize?" <> query
  end

  @doc "Exchanges the callback code for the user's GitHub profile."
  def fetch_profile(code, redirect_uri) do
    with {:ok, %{status: 200, body: %{"access_token" => token}}} <-
           Req.post(req(),
             url: "https://github.com/login/oauth/access_token",
             headers: [accept: "application/json"],
             form: [
               client_id: config()[:client_id],
               client_secret: config()[:client_secret],
               code: code,
               redirect_uri: redirect_uri
             ]
           ),
         {:ok, %{status: 200, body: %{} = profile}} <-
           Req.get(req(),
             url: "https://api.github.com/user",
             auth: {:bearer, token},
             headers: [accept: "application/vnd.github+json"]
           ) do
      {:ok, profile}
    else
      {:ok, %{body: body}} -> {:error, {:github, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    Req.new(
      [receive_timeout: 15_000] ++
        Application.get_env(:build_distro, :github_oauth_req_options, [])
    )
  end

  defp config, do: Application.get_env(:build_distro, :github_oauth, [])
end
