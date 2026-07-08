defmodule Words.Providers.Text do
  @moduledoc """
  Shared text-cleanup helpers for the HTML-scraping providers.

  Dictionary pages wrap words in nested spans and links, which makes
  plain text extraction lossy: joining child nodes without a separator
  glues English words together, while joining with one scatters spaces
  around punctuation. These helpers centralize the common repairs so
  each provider only declares its page-specific rules.
  """

  @english_rules [
    # no space before closing punctuation or closing quotes
    {~r/\s+([,.;:!?)”’])/u, "\\1"},
    # no space after opening brackets or opening quotes
    {~r/([(“‘])\s+/u, "\\1"}
  ]

  @doc """
  Collapses every whitespace run into a single space and trims the ends.
  """
  def normalize_space(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Extracts text from Floki nodes, joining child nodes with `sep`, then
  applies `{regex, replacement}` rules in order.
  """
  def squash(nodes, sep, rules \\ []) do
    initial = nodes |> Floki.text(sep: sep) |> normalize_space()

    Enum.reduce(rules, initial, fn {regex, replacement}, acc ->
      String.replace(acc, regex, replacement)
    end)
  end

  @doc """
  Extracts English text: child nodes are joined with spaces to restore
  word gaps, then punctuation spacing is repaired. Provider-specific
  `{regex, replacement}` rules run after the base ones.
  """
  def english_text(nodes, extra_rules \\ []) do
    squash(nodes, " ", @english_rules ++ extra_rules)
  end

  @doc """
  Splits a leading part-of-speech abbreviation off a definition line.

      iex> Words.Providers.Text.split_pos("int. 喂；哈罗")
      %{pos: "int.", meanings: ["喂；哈罗"]}

      iex> Words.Providers.Text.split_pos("网络释义")
      %{pos: "", meanings: ["网络释义"]}

  """
  def split_pos(text) do
    case Regex.run(~r/^((?:[a-z]+\.\s*)+)(.*)$/u, text) do
      [_, pos, meaning] -> %{pos: String.trim(pos), meanings: [String.trim(meaning)]}
      nil -> %{pos: "", meanings: [text]}
    end
  end

  @doc """
  Returns `nil` for an empty string, the string itself otherwise.
  """
  def presence(""), do: nil
  def presence(text), do: text
end
