defmodule Words.Providers.Longman do
  @moduledoc """
  Longman Dictionary of Contemporary English (ldoceonline.com) provider.

  A monolingual dictionary: example sentences have no Chinese
  translation, so `sentence.cn` is always empty.

  A page may contain several `.dictentry` blocks, including proper-noun
  entries (e.g. the *Hello!* magazine). The first entry with phonetic
  codes is treated as the primary one for the headword and
  pronunciations, while definitions are collected from all entries.
  """

  @behaviour Words.Provider

  alias Words.Entry
  alias Words.Providers.{HTTP, Text}

  @base_url "https://www.ldoceonline.com/dictionary/"

  # a plural "s" trailing a link gets separated by the join,
  # e.g. "<a>fashion model</a>s" -> "fashion model s"
  @plural_s_rule {~r/(\w) s(?=[\s,.;:!?)]|$)/u, "\\1s"}

  @impl Words.Provider
  def lookup(word) do
    slug =
      word
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    case HTTP.fetch_document(@base_url <> slug) do
      {:ok, doc} -> parse(doc)
      # unknown words redirect to a spellcheck page or 404
      {:error, {:http_error, 404}} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Extracts entry data from a parsed Floki document.

  Kept separate from the HTTP request so it can be tested offline
  against HTML fixtures.
  """
  def parse(doc) do
    entries =
      doc
      |> Floki.find(".dictentry")
      |> Enum.filter(&(Floki.find(&1, ".Head .HWD") != []))

    case entries do
      [] ->
        {:error, :not_found}

      entries ->
        # Proper-noun entries carry no phonetic codes; the entry that has
        # them is the primary lexical entry.
        primary = Enum.find(entries, hd(entries), &(pron_codes(&1) != ""))

        {:ok,
         %Entry{
           word: primary |> Floki.find(".Head .HWD") |> Floki.text() |> String.trim(),
           pronunciations: parse_pronunciations(primary),
           definitions: Enum.flat_map(entries, &parse_definitions/1),
           sentences: Enum.flat_map(entries, &parse_sentences/1),
           source: :longman
         }}
    end
  end

  defp pron_codes(entry) do
    entry |> Floki.find(".Head .PronCodes") |> Floki.text() |> Text.normalize_space()
  end

  # Head speakers carry a full mp3 URL in data-src-mp3 and mark the
  # region via "British"/"American" in their title attribute. The
  # phonetic codes read like "/həˈləʊ, he- $ -ˈloʊ/" where "$" separates
  # the British variant from the American one.
  defp parse_pronunciations(entry) do
    {uk_phonetic, us_phonetic} = entry |> pron_codes() |> split_pron_codes()

    entry
    |> Floki.find(".Head .speaker")
    |> Enum.map(fn speaker ->
      title = speaker |> Floki.attribute("title") |> List.first() || ""

      {region, phonetic} =
        cond do
          String.contains?(title, "British") -> {"英", uk_phonetic}
          String.contains?(title, "American") -> {"美", us_phonetic}
          true -> {nil, uk_phonetic}
        end

      %{
        region: region,
        phonetic: phonetic,
        audio_url: speaker |> Floki.attribute("data-src-mp3") |> List.first()
      }
    end)
    |> Enum.reject(&(&1.phonetic == "" and &1.audio_url == nil))
  end

  defp split_pron_codes(codes) do
    case codes |> String.trim("/") |> String.split("$", parts: 2) do
      [uk, us] -> {String.trim(uk), String.trim(us)}
      [both] -> {String.trim(both), String.trim(both)}
    end
  end

  # The part of speech lives in the entry head (.POS, e.g.
  # "interjection, noun"); each .Sense's .DEF is one English meaning.
  defp parse_definitions(entry) do
    pos = entry |> Floki.find(".Head .POS") |> Floki.text() |> Text.normalize_space()

    meanings =
      entry
      |> Floki.find(".Sense .DEF")
      |> Enum.map(&Text.english_text(&1, [@plural_s_rule]))
      |> Enum.reject(&(&1 == ""))

    if meanings == [], do: [], else: [%{pos: pos, meanings: meanings}]
  end

  # Examples are .EXAMPLE nodes inside senses, English only.
  defp parse_sentences(entry) do
    entry
    |> Floki.find(".Sense .EXAMPLE")
    |> Enum.map(&%{en: Text.english_text(&1, [@plural_s_rule]), cn: ""})
    |> Enum.reject(&(&1.en == ""))
  end
end
