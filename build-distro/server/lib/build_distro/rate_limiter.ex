defmodule BuildDistro.RateLimiter do
  @moduledoc "Fixed-window counters in ETS, for passcode and admin sign-in attempts."

  use GenServer

  @table __MODULE__
  @sweep_every :timer.minutes(5)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Counts one attempt for `key`. Returns `:error` once `limit` is reached in the window."
  def hit(key, limit, window_ms) do
    window = div(System.monotonic_time(:millisecond), window_ms)
    count = :ets.update_counter(@table, {key, window}, 1, {{key, window}, 0, window_ms})
    if count <= limit, do: :ok, else: :error
  end

  def reset(key) do
    :ets.match_delete(@table, {{key, :_}, :_, :_})
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    for {{_key, window} = id, _count, window_ms} <- :ets.tab2list(@table),
        window < div(now, window_ms) do
      :ets.delete(@table, id)
    end

    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
