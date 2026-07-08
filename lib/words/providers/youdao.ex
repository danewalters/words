defmodule Words.Providers.Youdao do
  @moduledoc """
  Youdao dictionary (dict.youdao.com) provider.

  Fetches the same page as `Words.Providers.Collins` but parses Youdao's
  own sections: basic definitions (`#phrsListTab`) and bilingual example
  sentences (`#bilingual`).
  """

  @behaviour Words.Provider

  alias Words.Entry
  alias Words.Providers.{HTTP, Text}

  @base_url "https://dict.youdao.com/w/eng/"
  @voice_url "https://dict.youdao.com/dictvoice?audio="

  # collapse contractions only ("it 's" -> "it's", letter right after
  # the apostrophe); quoted words ("' hello '") are left alone
  @contraction_rule {~r/(\w) '(\w)/u, "\\1'\\2"}

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
    case doc |> Floki.find(".keyword") |> Floki.text() |> String.trim() do
      "" ->
        {:error, :not_found}

      word ->
        {:ok,
         %Entry{
           word: word,
           pronunciations: parse_pronunciations(doc),
           definitions: parse_definitions(doc),
           sentences: parse_sentences(doc),
           source: :youdao
         }}
    end
  end

  # Each .baav .pronounce reads like "英 [həˈləʊ] <play button>"; the
  # .dictvoice data-rel value (e.g. "hello&type=1") becomes a playable
  # mp3 once appended to the dictvoice endpoint (type=1 UK, type=2 US).
  defp parse_pronunciations(doc) do
    doc
    |> Floki.find(".baav .pronounce")
    |> Enum.map(fn pron ->
      phonetic = pron |> Floki.find(".phonetic") |> Floki.text() |> String.trim()

      region =
        pron
        |> Floki.text()
        |> String.replace(phonetic, "")
        |> Text.normalize_space()

      audio_url =
        case pron |> Floki.find(".dictvoice") |> Floki.attribute("data-rel") do
          [rel | _] -> @voice_url <> rel
          [] -> nil
        end

      %{region: Text.presence(region), phonetic: phonetic, audio_url: audio_url}
    end)
    |> Enum.reject(&(&1.phonetic == "" and &1.audio_url == nil))
  end

  # Basic definitions live in #phrsListTab list items, each reading like
  # "int. 喂，你好……" with a leading part-of-speech abbreviation that is
  # split out (same format as Eudic).
  defp parse_definitions(doc) do
    doc
    |> Floki.find("#phrsListTab .trans-container ul li")
    |> Enum.map(fn li ->
      li |> Floki.text() |> Text.normalize_space() |> Text.split_pos()
    end)
    |> Enum.reject(&(&1.meanings == [""]))
  end

  # Bilingual examples live under #bilingual; each list item holds three
  # paragraphs: English, Chinese, and the source dictionary (discarded).
  # Both languages are split into per-word spans: English is joined with
  # spaces and cleaned up, Chinese is joined without them.
  defp parse_sentences(doc) do
    doc
    |> Floki.find("#bilingual ul li")
    |> Enum.map(fn li ->
      case Floki.find(li, "p") do
        [en, cn | _] ->
          %{en: Text.english_text([en], [@contraction_rule]), cn: chinese_text([cn])}

        _ ->
          %{en: "", cn: ""}
      end
    end)
    |> Enum.reject(&(&1.en == "" and &1.cn == ""))
  end

  # Removes the spaces the per-word spans leave between Han characters
  # and fullwidth punctuation.
  defp chinese_text(nodes) do
    nodes
    |> Floki.text()
    |> Text.normalize_space()
    |> String.replace(~r/\s+(?=[\p{Han}，。；：！？、）])/u, "")
    |> String.replace(~r/(?<=[\p{Han}，。；：！？、（])\s+/u, "")
  end
end
