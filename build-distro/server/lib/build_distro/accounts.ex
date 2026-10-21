defmodule BuildDistro.Accounts do
  @moduledoc """
  Admin accounts. An account is created the first time an allowed GitHub
  login signs in. The allow list in `ADMIN_GITHUB_LOGINS` is checked again on
  every request, so removing a login there ends that admin's access at once.
  """

  alias BuildDistro.Accounts.User
  alias BuildDistro.Repo

  @doc "Signs in a GitHub profile, creating or updating its account. Only admins may sign in."
  def sign_in(%{"id" => github_id, "login" => login} = profile)
      when is_integer(github_id) and is_binary(login) do
    if admin_login?(login) do
      attrs = %{
        github_id: github_id,
        login: login,
        name: profile["name"],
        avatar_url: profile["avatar_url"],
        last_sign_in_at: DateTime.utc_now()
      }

      (Repo.get_by(User, github_id: github_id) || %User{})
      |> User.changeset(attrs)
      |> Repo.insert_or_update()
    else
      {:error, :not_admin}
    end
  end

  def sign_in(_profile), do: {:error, :invalid_profile}

  @doc "The signed-in admin, or nil when the account is gone or no longer allowed."
  def get_admin(user_id) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{login: login} = user -> if admin_login?(login), do: user
      nil -> nil
    end
  end

  def get_admin(_), do: nil

  # GitHub logins are case-insensitive.
  defp admin_login?(login) do
    login = String.downcase(login)
    Enum.any?(admin_logins(), &(&1 == login))
  end

  def admin_logins do
    :build_distro
    |> Application.get_env(:admin_github_logins, [])
    |> Enum.map(&String.downcase/1)
  end
end
