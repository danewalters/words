defmodule Words.Providers.EudicTest do
  use ExUnit.Case, async: true

  alias Words.Entry
  alias Words.Providers.Eudic

  @fixture Path.expand("../../fixtures/eudic_hello.html", __DIR__)

  setup_all do
    {:ok, doc} = @fixture |> File.read!() |> Floki.parse_document()
    %{doc: doc}
  end

  describe "parse/1" do
    test "extracts the headword", %{doc: doc} do
      assert {:ok, %Entry{word: "hello", source: :eudic}} = Eudic.parse(doc)
    end

    test "extracts UK and US pronunciations with phonetics and audio", %{doc: doc} do
      {:ok, entry} = Eudic.parse(doc)

      assert [uk, us] = entry.pronunciations
      assert uk.region == "英"
      assert us.region == "美"
      assert uk.phonetic =~ ~r|^/.+/$|
      assert String.starts_with?(us.audio_url, "https://api.frdic.com/api/v2/speech/speakweb?")
    end

    test "splits the part of speech out of each definition", %{doc: doc} do
      {:ok, entry} = Eudic.parse(doc)

      assert length(entry.definitions) > 0

      for %{pos: pos, meanings: meanings} <- entry.definitions do
        assert is_binary(pos)
        assert meanings != []
        assert Enum.all?(meanings, &(is_binary(&1) and &1 != ""))
      end

      assert Enum.any?(entry.definitions, &(&1.pos == "n."))
    end

    test "decodes example sentences from the data attribute", %{doc: doc} do
      {:ok, entry} = Eudic.parse(doc)

      assert length(entry.sentences) > 0

      first = hd(entry.sentences)
      assert first.en =~ "Hello"
      refute first.en =~ "%"
      refute first.en =~ "+"
    end

    test "returns not_found when the page has no entry" do
      {:ok, doc} = Floki.parse_document("<html><body>nothing</body></html>")
      assert {:error, :not_found} = Eudic.parse(doc)
    end
  end
end
