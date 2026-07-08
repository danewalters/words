defmodule Words.Providers.CollinsTest do
  use ExUnit.Case, async: true

  alias Words.Entry
  alias Words.Providers.Collins

  @fixture Path.expand("../../fixtures/collins_hello.html", __DIR__)

  setup_all do
    {:ok, doc} = @fixture |> File.read!() |> Floki.parse_document()
    %{doc: doc}
  end

  describe "parse/1" do
    test "extracts the headword", %{doc: doc} do
      assert {:ok, %Entry{word: "hello", source: :collins}} = Collins.parse(doc)
    end

    test "extracts a single region-less pronunciation", %{doc: doc} do
      {:ok, entry} = Collins.parse(doc)

      assert [%{region: nil, phonetic: phonetic, audio_url: nil}] = entry.pronunciations
      assert phonetic =~ ~r|^/.+/$|
    end

    test "strips the COBUILD label from the meaning text", %{doc: doc} do
      {:ok, entry} = Collins.parse(doc)

      assert length(entry.definitions) > 1

      assert [%{pos: "CONVENTION", meanings: [first]} | _] = entry.definitions
      refute String.starts_with?(first, "CONVENTION")
      assert first =~ "你好"

      assert Enum.any?(entry.definitions, &(&1.pos == "N-COUNT"))
    end

    test "pairs English and Chinese example sentences", %{doc: doc} do
      {:ok, entry} = Collins.parse(doc)

      assert length(entry.sentences) > 0

      for %{en: en, cn: cn} <- entry.sentences do
        assert en != ""
        assert cn != ""
      end
    end

    test "returns not_found when the page has no Collins section" do
      {:ok, doc} = Floki.parse_document("<html><body>no collins here</body></html>")
      assert {:error, :not_found} = Collins.parse(doc)
    end
  end
end
