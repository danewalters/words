defmodule Words.Providers.Eudic do
  @moduledoc """
  Eudic dictionary (dict.eudic.net) provider.

  The word page is HTML, parsed with Floki and normalized into a
  `Words.Entry`.

  Known limitation: Eudic renders some Chinese words as
  `<img class="dictimgtoword">` images (an anti-scraping measure) with
  no alt text, so those words are missing from the extracted text.
  """

  @behaviour Words.Provider

  alias Words.Entry
  alias Words.Providers.{HTTP, Text}

  @base_url "https://dict.eudic.net/dicts/en/"
  @speech_url "https://api.frdic.com/api/v2/speech/speakweb?"

  @impl Words.Provider
  def lookup(word) do
    url = @base_url <> URI.encode(word, &URI.char_unreserved?/1)

    with {:ok, doc} <- HTTP.fetch_document(url) do
      parse(doc)
    end
  end

  @doc """
  Extracts entry data from a parsed Floki document.

  Kept separate from the HTTP request so it can be tested offline
  against HTML fixtures.
  """
  def parse(doc) do
    case Floki.find(doc, "h1.explain-Word .word") do
      [] ->
        {:error, :not_found}

      [word_node | _] ->
        {:ok,
         %Entry{
           word: word_node |> Floki.text() |> String.trim(),
           pronunciations: parse_pronunciations(doc),
           definitions: parse_definitions(doc),
           sentences: parse_sentences(doc),
           source: :eudic
         }}
    end
  end

  # Each a.voice-js in the phonetics line is one pronunciation variant:
  # span.phontype holds the region (英/美), span.Phonitic the IPA, and
  # the data-rel attribute becomes a playable mp3 URL once prefixed with
  # the speech API endpoint.
  defp parse_pronunciations(doc) do
    doc
    |> Floki.find(".phonitic-line a.voice-js")
    |> Enum.map(fn item ->
      region = item |> Floki.find(".phontype") |> Floki.text() |> String.trim()
      phonetic = item |> Floki.find(".Phonitic") |> Floki.text() |> String.trim()

      audio_url =
        case Floki.attribute(item, "data-rel") do
          [rel | _] -> @speech_url <> rel
          [] -> nil
        end

      %{region: Text.presence(region), phonetic: phonetic, audio_url: audio_url}
    end)
    |> Enum.reject(&(&1.phonetic == ""))
  end

  # English-Chinese definitions live in an ordered list under #ExpFCchild;
  # each item reads like "int. 喂；哈罗" with a leading part-of-speech
  # abbreviation that is split out.
  defp parse_definitions(doc) do
    doc
    |> Floki.find("#ExpFCchild .exp ol li")
    |> Enum.map(fn li ->
      li |> Floki.text() |> Text.normalize_space() |> Text.split_pos()
    end)
    |> Enum.reject(&(&1.meanings == [""]))
  end

  # Examples live under #ExpLJchild, one .lj_item each. The full English
  # sentence is stored www-form-encoded in the item's data attribute,
  # which is more reliable than the p.line text (words there can be
  # replaced by images). The Chinese translation is only available as
  # p.exp text.
  defp parse_sentences(doc) do
    doc
    |> Floki.find("#ExpLJchild .lj_item")
    |> Enum.map(fn item ->
      en =
        case Floki.attribute(item, "data") do
          [encoded | _] -> encoded |> URI.decode_www_form() |> Text.normalize_space()
          [] -> item |> Floki.find("p.line") |> Floki.text() |> Text.normalize_space()
        end

      cn = item |> Floki.find("p.exp") |> Floki.text() |> Text.normalize_space()

      %{en: en, cn: cn}
    end)
    |> Enum.reject(&(&1.en == "" and &1.cn == ""))
  end
end
