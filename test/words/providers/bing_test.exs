defmodule Words.Providers.BingTest do
  use ExUnit.Case, async: true

  alias Words.Entry
  alias Words.Providers.Bing

  @fixture Path.expand("../../fixtures/bing_hello.html", __DIR__)

  setup_all do
    {:ok, doc} = @fixture |> File.read!() |> Floki.parse_document()
    %{doc: doc}
  end

  describe "parse/1" do
    test "extracts the headword", %{doc: doc} do
      assert {:ok, %Entry{word: "hello", source: :bing}} = Bing.parse(doc)
    end

    test "extracts US and UK pronunciations with phonetics and audio", %{doc: doc} do
      {:ok, entry} = Bing.parse(doc)

      assert [us, uk] = entry.pronunciations
      assert us.region == "美国"
      assert uk.region == "英国"
      assert us.phonetic =~ ~r/^\[.+\]$/
      assert String.starts_with?(us.audio_url, "https://cn.bing.com/dict/mediamp3?")
    end

    test "groups definitions by part of speech without empty groups", %{doc: doc} do
      {:ok, entry} = Bing.parse(doc)

      assert length(entry.definitions) > 0

      for %{pos: pos, meanings: meanings} <- entry.definitions do
        assert is_binary(pos)
        assert meanings != []
        assert Enum.all?(meanings, &is_binary/1)
      end

      assert %{pos: "int."} = hd(entry.definitions)
    end

    test "pairs example sentences without stray spaces in Chinese", %{doc: doc} do
      {:ok, entry} = Bing.parse(doc)

      assert length(entry.sentences) > 0

      for %{en: en, cn: cn} <- entry.sentences do
        assert en != "" or cn != ""
        refute cn =~ ~r/\p{Han} \p{Han}/u
      end
    end

    test "returns not_found when the page has no entry" do
      {:ok, doc} = Floki.parse_document("<html><body>nothing</body></html>")
      assert {:error, :not_found} = Bing.parse(doc)
    end
  end
end
