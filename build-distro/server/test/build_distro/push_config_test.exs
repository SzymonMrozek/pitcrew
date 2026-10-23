defmodule BuildDistro.PushConfigTest do
  use ExUnit.Case, async: false

  @variables ~w(VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  test "push is optional and a partial keypair is rejected" do
    refute Keyword.has_key?(read_config(), :web_push)
    System.put_env("VAPID_PUBLIC_KEY", WebPush.Vapid.generate_keypair().public_key)
    assert_raise RuntimeError, ~r/Set VAPID_PUBLIC_KEY/, &read_config/0
  end

  test "a matching keypair accepts both contact URL forms and mismatches fail" do
    keys = WebPush.Vapid.generate_keypair()
    System.put_env("VAPID_PUBLIC_KEY", keys.public_key)
    System.put_env("VAPID_PRIVATE_KEY", keys.private_key)

    for subject <- ["mailto:admin@example.com", "https://builds.example.com"] do
      System.put_env("VAPID_SUBJECT", subject)
      assert read_config()[:web_push][:vapid][:subject] == subject
    end

    System.put_env("VAPID_PRIVATE_KEY", WebPush.Vapid.generate_keypair().private_key)
    assert_raise RuntimeError, ~r/valid matching keypair/, &read_config/0
  end

  defp read_config, do: Config.Reader.read!("config/runtime.exs", env: :test)
end
