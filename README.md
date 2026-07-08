# Words

A multi-source dictionary lookup library for Elixir. Query five online
dictionaries through one API, get back one normalized struct — with
concurrent fan-out, fault isolation, and a built-in ETS cache.

```elixir
iex> {:ok, entry} = Words.lookup("hello")
iex> entry.definitions
[
  %{pos: "int.", meanings: ["你好；喂；您好；哈喽"]},
  %{pos: "网络", meanings: ["哈罗；哈啰；大家好"]},
  ...
]
```

> Built as a learning project for Elixir/OTP — behaviours, supervision
> trees, `Task.Supervisor`, GenServer + ETS caching, and `Req.Test`
> based testing. The scraping targets may change or rate-limit at any
> time; treat it as a personal tool, not a production service.

## Features

- **Five dictionary sources** behind a single `Words.Provider` behaviour
- **One normalized result type** — `Words.Entry` with pronunciations
  (phonetic + audio URL), definitions grouped by part of speech, and
  bilingual example sentences
- **Concurrent fan-out** — `Words.lookup_all/1` queries every source at
  once; a slow, failing, or crashing source is reported as data and
  never hides the others' results
- **In-memory cache** — generational ETS cache (an LRU approximation)
  with separate TTLs for hits and not-found results; transient errors
  are never cached. Fully configurable, or disable it entirely
- **Offline test suite** — 48 tests run in ~0.2s against saved HTML
  fixtures and `Req.Test` stubs, zero network required

## Supported sources

| Provider | Source | Definitions | Examples | Notes |
|---|---|---|---|---|
| `:bing` (default) | cn.bing.com/dict | zh | en + zh | |
| `:eudic` | dict.eudic.net | zh | en + zh | some Chinese words rendered as images by the site are lost |
| `:youdao` | dict.youdao.com | zh | en + zh | word audio via the dictvoice endpoint |
| `:collins` | Collins COBUILD via Youdao | en + zh | en + zh | official site is behind a Cloudflare JS challenge; data read from the licensed section embedded in Youdao |
| `:longman` | ldoceonline.com | en | en only | monolingual; `sentence.cn` is always `""` |

## Installation

Not published to Hex. Use it as a path or git dependency:

```elixir
def deps do
  [
    {:words, path: "../words"}
    # or: {:words, git: "https://github.com/you/words.git"}
  ]
end
```

Requires Elixir ~> 1.20.

## Usage

### Single source

```elixir
{:ok, entry} = Words.lookup("hello")                      # default provider (:bing)
{:ok, entry} = Words.lookup("hello", provider: :longman)  # pick a source

entry.word            #=> "hello"
entry.source          #=> :longman
entry.pronunciations  #=> [%{region: "英", phonetic: "həˈləʊ, he-", audio_url: "https://..."}, ...]
entry.definitions     #=> [%{pos: "interjection, noun", meanings: ["used as a greeting ...", ...]}]
entry.sentences       #=> [%{en: "Hello, John! How are you?", cn: ""}, ...]
```

### All sources, concurrently

```elixir
Words.lookup_all("hello")
#=> %{
#     bing:    {:ok, %Words.Entry{...}},
#     collins: {:ok, %Words.Entry{...}},
#     eudic:   {:ok, %Words.Entry{...}},
#     longman: {:error, {:task_exit, :timeout}},   # one slow source doesn't block the rest
#     youdao:  {:ok, %Words.Entry{...}}
#   }
```

Failures are data, not exceptions: each provider reports its own
`{:ok, entry}` or `{:error, reason}`. Providers run unlinked under a
`Task.Supervisor`, so even a crashing provider is isolated and reported
as `{:error, {:task_exit, reason}}`.

### Errors

| Error | Meaning |
|---|---|
| `{:error, :empty_word}` | input is empty or whitespace-only |
| `{:error, :word_too_long}` | input exceeds 64 bytes |
| `{:error, :not_found}` | the word is not in that dictionary |
| `{:error, {:unknown_provider, name}}` | no such provider registered |
| `{:error, {:http_error, status}}` | source responded with a non-200 status |
| `{:error, {:task_exit, reason}}` | (`lookup_all/1` only) provider timed out or crashed |

## Configuration

All configuration is optional; these are the defaults:

```elixir
config :words,
  cache: [
    enabled: true,            # false = skip caching entirely, always fetch fresh
    max_entries: 10_000,      # per cache generation (live total may reach 2x)
    ttl: :timer.hours(6),     # for {:ok, entry} results
    negative_ttl: :timer.minutes(10)  # for {:error, :not_found} (negative cache)
  ],
  lookup_all_timeout: 6_000   # per-provider deadline in lookup_all/1, ms
```

Values are read when used, so they can also be changed at runtime via
`Application.put_env/3`. Transient failures (HTTP errors, timeouts) are
never cached regardless of settings.

## Architecture

```
Words                      facade: validation, cache check, dispatch
├── Words.Entry            normalized result struct
├── Words.Provider         behaviour: @callback lookup(word)
├── Words.Cache            GenServer owning two ETS generations
│                          (reads bypass it and hit ETS directly)
├── Words.Providers.HTTP   shared fetch: UA, timeouts, status handling
├── Words.Providers.Text   shared text cleanup for scraped HTML
└── Words.Providers.*      one module per source: build URL + parse
```

Design notes, in the order they shaped the code:

- **Provider contract.** Every source implements `lookup/1` and returns
  a `Words.Entry`; adding a source is one module plus one line in the
  facade's registry. Each provider's `parse/1` is a pure function over
  a Floki document, kept separate from HTTP so it can be tested against
  fixtures.
- **Fault isolation.** `lookup_all/1` uses
  `Task.Supervisor.async_stream_nolink/4`: tasks are not linked to the
  caller, so a provider crash becomes an `{:exit, reason}` stream
  element instead of taking the whole query down.
- **Cache.** Reads run in the caller's process straight against ETS;
  the GenServer owns the tables and serializes writes, promotions,
  generation rotation and expiry sweeps. Capacity is bounded by
  two-generation rotation — an LRU approximation that never requires
  the read path to write.

## Testing

```sh
mix test
```

The suite is fully offline: provider parsers run against saved HTML
fixtures in `test/fixtures/`, and the HTTP layer is routed to
[`Req.Test`](https://hexdocs.pm/req/Req.Test.html) stubs in
`test_helper.exs`. Covered paths include parsing for all five sources,
dispatch, HTTP errors, timeout and crash isolation in `lookup_all/1`,
and the cache (TTL expiry, negative caching, generational eviction and
promotion).

Fixtures are snapshots — if a site redesigns its pages, tests stay
green while live lookups break. Re-save the fixture and adjust the
parser when that happens.

## Acknowledgements

Selector research for several providers referenced
[Saladict](https://github.com/crimx/ext-saladict)'s dictionary engines.
