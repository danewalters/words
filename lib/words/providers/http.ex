defmodule Words.Providers.HTTP do
  @moduledoc """
  Shared HTTP layer for the providers.

  Every request carries a browser User-Agent (several sources reject
  the default client identifier) and uses a short receive timeout with
  retries disabled — for an interactive lookup, failing fast beats
  retrying slowly.

  Additional Req options can be injected through the `:req_options`
  application env; the test suite uses this to route requests to
  `Req.Test` stubs instead of the network.
  """

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

  @defaults [
    headers: [user_agent: @user_agent],
    receive_timeout: 5_000,
    retry: false
  ]

  @doc """
  Fetches `url` with a GET request and parses the body as HTML.

  Extra `opts` (e.g. `:params`) are passed through to `Req.get/2`.

  Returns `{:ok, document}` on a 200 response,
  `{:error, {:http_error, status}}` on any other status, or the
  transport error as-is.
  """
  def fetch_document(url, opts \\ []) do
    req_options =
      @defaults
      |> Keyword.merge(opts)
      |> Keyword.merge(Application.get_env(:words, :req_options, []))

    case Req.get(url, req_options) do
      {:ok, %Req.Response{status: 200, body: html}} -> Floki.parse_document(html)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
