defmodule Words.Providers.LongmanTest do
  use ExUnit.Case, async: true

  alias Words.Entry
  alias Words.Providers.Longman

  @fixture Path.expand("../../fixtures/longman_hello.html", __DIR__)

  setup_all do
    {:ok, doc} = @fixture |> File.read!() |> Floki.parse_document()
    %{doc: doc}
  end

  describe "parse/1" do
    test "picks the entry with phonetic codes as the primary one", %{doc: doc} do
      # the first .dictentry on the page is the Hello! magazine
      assert {:ok, %Entry{word: "hello", source: :longman}} = Longman.parse(doc)
    end

    test "splits UK/US phonetics on the $ separator with full audio URLs", %{doc: doc} do
      {:ok, entry} = Longman.parse(doc)

      assert [uk, us] = entry.pronunciations
      assert uk.region == "英"
      assert us.region == "美"
      assert uk.phonetic != us.phonetic
      assert String.starts_with?(uk.audio_url, "https://www.ldoceonline.com/media/")
    end

    test "collects definitions from all entries with the primary POS", %{doc: doc} do
      {:ok, entry} = Longman.parse(doc)

      assert Enum.any?(entry.definitions, &(&1.pos =~ "interjection"))

      for %{meanings: meanings} <- entry.definitions do
        assert meanings != []
        assert Enum.all?(meanings, &(is_binary(&1) and &1 != ""))
      end
    end

    test "extracts English-only example sentences", %{doc: doc} do
      {:ok, entry} = Longman.parse(doc)

      assert length(entry.sentences) > 0
      assert Enum.all?(entry.sentences, &(&1.en != "" and &1.cn == ""))
      refute Enum.any?(entry.sentences, &(&1.en =~ "  "))
    end

    test "returns not_found when the page has no entry" do
      {:ok, doc} = Floki.parse_document("<html><body>did you mean</body></html>")
      assert {:error, :not_found} = Longman.parse(doc)
    end
  end
end
