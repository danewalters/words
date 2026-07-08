defmodule Words.Provider do
  @moduledoc """
  Behaviour contract for dictionary sources.

  Every provider must implement `c:lookup/1` and normalize its result
  into a `Words.Entry`. Providers are registered in the `Words` facade;
  adding a new source means implementing this behaviour and adding one
  entry to that registry.
  """

  @callback lookup(word :: String.t()) :: {:ok, Words.Entry.t()} | {:error, term()}
end
