defmodule Words.Cache do
  @moduledoc """
  In-memory cache for lookup results, backed by two ETS generations.

  ## Design

  Reads run in the **caller's process**, straight against ETS — they
  never touch this GenServer, so cache hits are lock-free and
  concurrent. The GenServer owns the tables (they die and get rebuilt
  with it — losing a cache is fine, "let it crash") and serializes
  everything that writes: inserts, promotions, generation rotation and
  the periodic sweep of expired entries.

  Capacity is bounded by **generational rotation**, an LRU
  approximation: writes go to the `new` table; when it reaches
  `:max_entries` the `old` table is dropped, `new` becomes `old`, and a
  fresh `new` table is created. A read that hits `old` promotes the
  entry back into `new`, so anything recently read survives rotation —
  what gets evicted is exactly the generation nobody touched. Total
  size is therefore bounded by `2 * max_entries`.

  ## What gets cached

    * `{:ok, entry}` — dictionary data barely changes; cached with `:ttl`
    * `{:error, :not_found}` — negative cache with the shorter
      `:negative_ttl`, so a repeated typo doesn't hammer the source
    * transient failures (HTTP errors, timeouts, crashes) — **never**
      cached: that would amplify one hiccup into a long outage

  Expiry uses `System.monotonic_time/1`, which cannot jump backwards
  the way wall-clock time can.

  ## Configuration

  All keys are optional; these are the defaults:

      config :words, cache: [
        enabled: true,            # `false` makes the facade skip caching entirely
        max_entries: 10_000,      # per generation (live total may reach 2x)
        ttl: :timer.hours(6),
        negative_ttl: :timer.minutes(10)
      ]

  Values are read when used, not at startup, so they can also be set
  at runtime with `Application.put_env/3`.
  """

  use GenServer

  @new_table Words.Cache.New
  @old_table Words.Cache.Old

  @defaults [
    enabled: true,
    max_entries: 10_000,
    ttl: :timer.hours(6),
    negative_ttl: :timer.minutes(10)
  ]

  @sweep_interval :timer.minutes(10)

  ## Client API — these functions run in the caller's process

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether the cache is enabled (the `:enabled` config key).
  """
  def enabled? do
    config(:enabled)
  end

  @doc """
  Fetches a cached result. Returns `{:hit, result}` or `:miss`.

  Reads ETS directly without going through the cache process. A hit in
  the old generation is promoted back into the new one, but the
  promotion itself is handed to the owner process — the read path
  never writes.
  """
  def get(provider, word) do
    key = {provider, word}
    now = System.monotonic_time(:millisecond)

    case lookup(@new_table, key, now) do
      {:hit, result, _expires_at} ->
        {:hit, result}

      :miss ->
        case lookup(@old_table, key, now) do
          {:hit, result, expires_at} ->
            GenServer.cast(__MODULE__, {:promote, key, result, expires_at})
            {:hit, result}

          :miss ->
            :miss
        end
    end
  end

  @doc """
  Stores a lookup result. The TTL policy (or refusal to cache at all)
  is decided by the shape of `result` — see the module docs.

  Asynchronous by design: the caller already holds the result, so it
  has nothing to gain from waiting for the write to be acknowledged.
  """
  def put(provider, word, result) do
    GenServer.cast(__MODULE__, {:put, {provider, word}, result})
  end

  @doc """
  Drops every cached entry. Synchronous; mainly useful in tests.
  """
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  defp lookup(table, key, now) do
    case :ets.lookup(table, key) do
      [{^key, result, expires_at}] when now < expires_at -> {:hit, result, expires_at}
      _ -> :miss
    end
  rescue
    # A generation rotation deletes and renames tables; a read landing
    # exactly in that window sees a missing table. Treat it as a miss.
    ArgumentError -> :miss
  end

  ## Server callbacks — these run in the cache process

  @impl true
  def init(_opts) do
    create_table(@new_table)
    create_table(@old_table)
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:put, key, result}, state) do
    case ttl_for(result) do
      :skip -> :ok
      ttl -> insert(key, result, System.monotonic_time(:millisecond) + ttl)
    end

    {:noreply, state}
  end

  def handle_cast({:promote, key, result, expires_at}, state) do
    :ets.delete(@old_table, key)
    insert(key, result, expires_at)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@new_table)
    :ets.delete_all_objects(@old_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    expired = [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@new_table, expired)
    :ets.select_delete(@old_table, expired)
    schedule_sweep()
    {:noreply, state}
  end

  defp insert(key, result, expires_at) do
    if :ets.info(@new_table, :size) >= config(:max_entries), do: rotate()
    :ets.insert(@new_table, {key, result, expires_at})
  end

  defp ttl_for({:ok, _entry}), do: config(:ttl)
  defp ttl_for({:error, :not_found}), do: config(:negative_ttl)
  defp ttl_for(_transient_failure), do: :skip

  defp rotate do
    :ets.delete(@old_table)
    :ets.rename(@new_table, @old_table)
    create_table(@new_table)
  end

  defp create_table(name) do
    :ets.new(name, [:set, :named_table, :protected, read_concurrency: true])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp config(key) do
    :words
    |> Application.get_env(:cache, [])
    |> Keyword.get(key, @defaults[key])
  end
end
