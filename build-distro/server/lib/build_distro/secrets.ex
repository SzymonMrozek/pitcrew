defmodule BuildDistro.Secrets do
  @moduledoc """
  Hashing for everything that grants access. The database is replicated to the
  bucket, so it only ever holds hashes.
  """

  @doc "A random token with a readable prefix, for API keys and invite links."
  def generate_token(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  @doc "Tokens are random, so a fast hash is enough to store them."
  def hash_token(token), do: :crypto.hash(:sha256, token)

  @doc "Passcodes are chosen by people, so they get a slow, salted hash."
  def hash_passcode(passcode) do
    salt = :crypto.strong_rand_bytes(16)
    iterations = iterations()
    hash = :crypto.pbkdf2_hmac(:sha256, passcode, salt, iterations, 32)
    Enum.join(["pbkdf2-sha256", iterations, Base.encode64(salt), Base.encode64(hash)], "$")
  end

  def verify_passcode(passcode, encoded) when is_binary(passcode) and is_binary(encoded) do
    with ["pbkdf2-sha256", iterations, salt, hash] <- String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      candidate = :crypto.pbkdf2_hmac(:sha256, passcode, salt, iterations, byte_size(hash))
      Plug.Crypto.secure_compare(candidate, hash)
    else
      _ -> false
    end
  end

  def verify_passcode(_, _), do: false

  defp iterations, do: Application.get_env(:build_distro, :passcode_iterations, 600_000)
end
