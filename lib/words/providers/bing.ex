defmodule Words.Providers.Bing do
  @moduledoc """
  Bing Dictionary (cn.bing.com/dict) provider.

  The `clientsearch` endpoint returns HTML, which is parsed with Floki
  and normalized into a `Words.Entry`.
  """

  @behaviour Words.Provider

  alias Words.Entry
  alias Words.Providers.{HTTP, Text}

  @base_url "https://cn.bing.com/dict/clientsearch"
  @host "https://cn.bing.com"
  @params [mkt: "zh-CN", setLang: "zh", form: "BDVEHC", ClientVer: "BDDTV3.5.1.4320"]

  # covers both Western and CJK punctuation, as examples mix the two
  @punctuation_rule {~r/\s+([,.;:!?，。；：！？])/u, "\\1"}

  @impl Words.Provider
  def lookup(word) do
    with {:ok, doc} <- HTTP.fetch_document(@base_url, params: @params ++ [q: word]) do
      parse(doc)
    end
  end

  @doc """
  Extracts entry data from a parsed Floki document.

  Kept separate from the HTTP request so it can be tested offline
  against HTML fixtures.
  """
  def parse(doc) do
    case Floki.find(doc, ".client_def_hd_hd") do
      [] ->
        {:error, :not_found}

      [word_node | _] ->
        {:ok,
         %Entry{
           word: word_node |> Floki.text() |> String.trim(),
           pronunciations: parse_pronunciations(doc),
           definitions: parse_definitions(doc),
           sentences: parse_sentences(doc),
           source: :bing
         }}
    end
  end

  # Each .client_def_hd_pn_list holds one pronunciation variant:
  # .client_def_hd_pn reads like "美国: [heˈləʊ]" and .clientlistenword
  # carries the mp3 path in its data-pronunciation attribute.
  defp parse_pronunciations(doc) do
    doc
    |> Floki.find(".client_def_hd_pn_list")
    |> Enum.map(fn item ->
      {region, phonetic} =
        item
        |> Floki.find(".client_def_hd_pn")
        |> Floki.text()
        |> split_pronunciation()

      audio_url =
        case item |> Floki.find(".clientlistenword") |> Floki.attribute("data-pronunciation") do
          [path | _] -> @host <> path
          [] -> nil
        end

      %{region: region, phonetic: phonetic, audio_url: audio_url}
    end)
  end

  defp split_pronunciation(text) do
    case String.split(text, ":", parts: 2) do
      [region, phonetic] -> {String.trim(region), Text.normalize_space(phonetic)}
      [phonetic] -> {nil, Text.normalize_space(phonetic)}
    end
  end

  # Each .client_def_bar is one part-of-speech group: the tag lives in
  # .client_def_title (or .client_def_title_web for web-sourced meanings)
  # and each meaning in .client_def_list_word_bar. Blocks like
  # "collocations" reuse .client_def_bar with a different inner structure
  # and parse to empty groups, which are dropped.
  defp parse_definitions(doc) do
    doc
    |> Floki.find(".client_def_bar")
    |> Enum.map(fn bar ->
      pos =
        bar
        |> Floki.find(".client_def_title, .client_def_title_web")
        |> Floki.text()
        |> String.trim()

      meanings =
        bar
        |> Floki.find(".client_def_list_word_bar")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      %{pos: pos, meanings: meanings}
    end)
    |> Enum.reject(&(&1.meanings == []))
  end

  # Each .client_sentence_list is one example: English in .client_sen_en,
  # Chinese in .client_sen_cn. Both are split into per-word spans, so
  # English needs a space separator while Chinese must be joined without
  # one (spaces would break up the words).
  defp parse_sentences(doc) do
    doc
    |> Floki.find(".client_sentence_list")
    |> Enum.map(fn item ->
      %{
        en: item |> Floki.find(".client_sen_en") |> Text.squash(" ", [@punctuation_rule]),
        cn: item |> Floki.find(".client_sen_cn") |> Text.squash("", [@punctuation_rule])
      }
    end)
    |> Enum.reject(&(&1.en == "" and &1.cn == ""))
  end
end
