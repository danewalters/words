defmodule Words.Providers.YoudaoTest do
  use ExUnit.Case, async: true

  alias Words.Entry
  alias Words.Providers.Youdao

  @fixture Path.expand("../../fixtures/youdao_hello.html", __DIR__)

  setup_all do
    {:ok, doc} = @fixture |> File.read!() |> Floki.parse_document()
    %{doc: doc}
  end

  describe "parse/1" do
    test "extracts the headword", %{doc: doc} do
      assert {:ok, %Entry{word: "hello", source: :youdao}} = Youdao.parse(doc)
    end

    test "extracts UK and US pronunciations with dictvoice audio", %{doc: doc} do
      {:ok, entry} = Youdao.parse(doc)

      assert [uk, us] = entry.pronunciations
      assert uk.region == "英"
      assert us.region == "美"
      assert uk.phonetic =~ ~r/^\[.+\]$/
      assert uk.audio_url == "https://dict.youdao.com/dictvoice?audio=hello&type=1"
      assert us.audio_url == "https://dict.youdao.com/dictvoice?audio=hello&type=2"
    end

    test "splits the part of speech out of each definition", %{doc: doc} do
      {:ok, entry} = Youdao.parse(doc)

      poses = Enum.map(entry.definitions, & &1.pos)
      assert "int." in poses
      assert "n." in poses

      for %{meanings: meanings} <- entry.definitions do
        assert Enum.all?(meanings, &(is_binary(&1) and &1 != ""))
      end
    end

    test "pairs bilingual examples, dropping the source label", %{doc: doc} do
      {:ok, entry} = Youdao.parse(doc)

      assert length(entry.sentences) > 0

      for %{en: en, cn: cn} <- entry.sentences do
        assert en != ""
        assert cn != ""
        refute cn =~ "词典"
        refute cn =~ ~r/\p{Han} \p{Han}/u
      end
    end

    test "returns not_found when the page has no entry" do
      {:ok, doc} = Floki.parse_document("<html><body>nothing</body></html>")
      assert {:error, :not_found} = Youdao.parse(doc)
    end
  end
end
