defmodule Words do
  @moduledoc """
  Public API for dictionary lookups.

      Words.lookup("hello")                     # default provider
      Words.lookup("hello", provider: :youdao)  # specific provider
      Words.lookup_all("hello")                 # every provider, concurrently

  Dispatches to `Words.Provider` implementations. All providers
  normalize their results into a `Words.Entry` struct, so callers never
  deal with source-specific formats.

  ## Caching

  Results are cached in memory by `Words.Cache` — dictionary data
  barely changes, so repeat lookups are served without any network
  request. Both `lookup/2` and `lookup_all/1` share the same cache.
  Configure or disable it via the application env:

      config :words, cache: [enabled: false]                       # always fetch fresh
      config :words, cache: [max_entries: 1_000, ttl: :timer.hours(24)]

  See `Words.Cache` for the full option list and the caching policy.
  """

  alias Words.Cache

  @providers %{
    bing: Words.Providers.Bing,
    collins: Words.Providers.Collins,
    eudic: Words.Providers.Eudic,
    longman: Words.Providers.Longman,
    youdao: Words.Providers.Youdao
  }

  @default_provider :bing

  # Must exceed the HTTP layer's receive_timeout (5s): a slow source
  # should surface as its own transport error, not as a killed task —
  # the former carries more information. Overridable via the
  # :lookup_all_timeout application env (tests use a tiny value).
  @lookup_all_timeout 6_000

  # Anything longer than this is not a dictionary word; rejecting it
  # up front keeps garbage out of both the network path and the cache.
  @max_word_bytes 64

  @doc """
  Looks up a word and returns `{:ok, %Words.Entry{}}`.

  The word is trimmed before dispatch; providers never see
  leading/trailing whitespace.

  ## Options

    * `:provider` - the dictionary source, defaults to `#{inspect(@default_provider)}`.
      Available providers: `#{@providers |> Map.keys() |> inspect()}`

  ## Errors

    * `{:error, :empty_word}` - the input is empty or whitespace-only
    * `{:error, :word_too_long}` - the input exceeds #{@max_word_bytes} bytes
    * `{:error, :not_found}` - the word is not in the dictionary
    * `{:error, {:unknown_provider, name}}` - no such provider registered
    * `{:error, {:http_error, status}}` - the source responded with a non-200 status
    * other error tuples for network or parsing failures
  """
  @spec lookup(String.t(), keyword()) :: {:ok, Words.Entry.t()} | {:error, term()}
  def lookup(word, opts \\ []) when is_binary(word) do
    provider = Keyword.get(opts, :provider, @default_provider)

    with {:ok, word} <- validate_word(word),
         {:ok, module} <- provider_module(provider) do
      cached_lookup(provider, module, word)
    end
  end

  @doc """
  Looks up a word on every registered provider concurrently.

  Returns a map keyed by provider name. A failing source is data, not
  an exception: each value is that provider's own `{:ok, entry}` or
  `{:error, reason}`, so one slow or broken dictionary never hides the
  others' results. A provider that exceeds #{@lookup_all_timeout}ms or
  crashes is killed and reported as `{:error, {:task_exit, reason}}`.

      Words.lookup_all("hello")
      #=> %{
      #     bing: {:ok, %Words.Entry{...}},
      #     longman: {:error, {:task_exit, :timeout}},
      #     ...
      #   }

  Invalid input short-circuits: every provider is reported with the
  validation error (e.g. `{:error, :empty_word}`) and no network
  request is made.
  """
  @spec lookup_all(String.t()) :: %{atom() => {:ok, Words.Entry.t()} | {:error, term()}}
  def lookup_all(word) when is_binary(word) do
    case validate_word(word) do
      {:ok, trimmed} -> run_all(trimmed)
      {:error, reason} -> Map.new(@providers, fn {name, _} -> {name, {:error, reason}} end)
    end
  end

  defp run_all(word) do
    providers = Map.to_list(@providers)

    # The nolink variant keeps a crashing provider from taking this
    # process down with it: plain async_stream links its tasks to the
    # caller, so an unexpected raise inside one lookup would propagate
    # here and lose all five results. Unlinked, a crash becomes an
    # {:exit, reason} element in the stream, same as a timeout.
    Words.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      providers,
      fn {name, module} -> {name, cached_lookup(name, module, word)} end,
      timeout: lookup_all_timeout(),
      on_timeout: :kill_task
    )
    # Results come back in input order (ordered: true is the default),
    # so zipping against the provider list lets a killed task still be
    # attributed to its provider — a bare {:exit, reason} carries no
    # identity of its own.
    |> Enum.zip(providers)
    |> Map.new(fn
      {{:ok, {name, result}}, _} -> {name, result}
      {{:exit, reason}, {name, _module}} -> {name, {:error, {:task_exit, reason}}}
    end)
  end

  defp cached_lookup(name, module, word) do
    if Cache.enabled?() do
      lookup_through_cache(name, module, word)
    else
      module.lookup(word)
    end
  end

  defp lookup_through_cache(name, module, word) do
    case Cache.get(name, word) do
      {:hit, result} ->
        result

      :miss ->
        result = module.lookup(word)
        Cache.put(name, word, result)
        result
    end
  end

  defp lookup_all_timeout do
    Application.get_env(:words, :lookup_all_timeout, @lookup_all_timeout)
  end

  defp validate_word(word) do
    trimmed = String.trim(word)

    cond do
      trimmed == "" -> {:error, :empty_word}
      byte_size(trimmed) > @max_word_bytes -> {:error, :word_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp provider_module(name) do
    case Map.fetch(@providers, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, name}}
    end
  end
end
