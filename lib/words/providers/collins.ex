defmodule Words.Providers.Collins do
  @moduledoc """
  Collins COBUILD Advanced Learner's English-Chinese Dictionary provider.

  The official site (collinsdictionary.com) sits behind a Cloudflare
  JS challenge that plain HTTP clients cannot pass, so this provider
  reads the licensed Collins section (`#collinsResult`) embedded in the
  Youdao dictionary web page instead — Collins data, fetched via Youdao.

  Part-of-speech tags are COBUILD-style labels such as CONVENTION,
  N-COUNT or VERB rather than traditional abbreviations.
  """

  @behaviour Words.Provider

  alias Words.Entry
  alias Words.Providers.{HTTP, Text}

  @base_url "https://dict.youdao.com/w/eng/"

  @impl Words.Provider
  def lookup(word) do
    url = @base_url <> URI.encode(word, &URI.char_unreserved?/1)

    with {:ok, doc} <- HTTP.fetch_document(url) do
      parse(doc)
    end
  end

  @doc """
  Extracts Collins entry data from a parsed Floki document.

  Kept separate from the HTTP request so it can be tested offline
  against HTML fixtures.
  """
  def parse(doc) do
    collins = Floki.find(doc, "#collinsResult")

    case Floki.find(collins, ".wt-container .title") do
      [] ->
        {:error, :not_found}

      [title | _] ->
        {:ok,
         %Entry{
           word: title |> Floki.text(sep: " ") |> Text.normalize_space() |> first_word(),
           pronunciations: parse_pronunciations(collins),
           definitions: parse_definitions(collins),
           sentences: parse_sentences(collins),
           source: :collins
         }}
    end
  end

  # The .title node mixes the headword with other inline nodes
  # (phonetics, star rating), so only the first token is the word.
  defp first_word(text) do
    text |> String.split(" ", parts: 2) |> hd()
  end

  # The Collins section provides a single IPA transcription with no
  # UK/US distinction and no audio.
  defp parse_pronunciations(collins) do
    case collins
         |> Floki.find(".wt-container .phonetic")
         |> Floki.text()
         |> Text.normalize_space() do
      "" -> []
      phonetic -> [%{region: nil, phonetic: phonetic, audio_url: nil}]
    end
  end

  # Each list item is one sense. The .collinsMajorTrans paragraph mixes
  # the COBUILD label, the English definition and the Chinese
  # translation; the label sits in a leading .additional span and is
  # stripped from the meaning text.
  defp parse_definitions(collins) do
    collins
    |> Floki.find(".ol li .collinsMajorTrans")
    |> Enum.map(fn major ->
      text = major |> Floki.find("p") |> Text.english_text()
      pos = major |> Floki.find("p .additional") |> List.first() |> pos_text()

      meaning =
        if pos != "" and String.starts_with?(text, pos) do
          text |> String.trim_leading(pos) |> String.trim()
        else
          text
        end

      %{pos: pos, meanings: [meaning]}
    end)
    |> Enum.reject(&(&1.meanings == [""]))
  end

  defp pos_text(nil), do: ""
  defp pos_text(node), do: node |> Floki.text() |> Text.normalize_space()

  # Each sense's .examples div holds a pair of paragraphs:
  # English first, Chinese second.
  defp parse_sentences(collins) do
    collins
    |> Floki.find(".ol li .examples")
    |> Enum.map(fn examples ->
      case Floki.find(examples, "p") do
        [en, cn | _] ->
          %{en: Text.english_text([en]), cn: cn |> Floki.text() |> Text.normalize_space()}

        [en] ->
          %{en: Text.english_text([en]), cn: ""}

        [] ->
          %{en: "", cn: ""}
      end
    end)
    |> Enum.reject(&(&1.en == ""))
  end
end
