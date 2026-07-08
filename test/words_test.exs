defmodule WordsTest do
  use ExUnit.Case, async: true

  @bing_fixture Path.expand("fixtures/bing_hello.html", __DIR__)

  test "rejects blank input before any network call" do
    assert {:error, :empty_word} = Words.lookup("")
    assert {:error, :empty_word} = Words.lookup("   ")
  end

  test "returns an error for an unknown provider" do
    assert {:error, {:unknown_provider, :nope}} = Words.lookup("hello", provider: :nope)
  end

  test "rejects overlong input before any network call" do
    long = String.duplicate("a", 65)

    assert {:error, :word_too_long} = Words.lookup(long)

    results = Words.lookup_all(long)
    assert Enum.all?(results, fn {_name, result} -> result == {:error, :word_too_long} end)
  end

  test "dispatches to the selected provider" do
    Req.Test.stub(Words.Providers.HTTP, fn conn ->
      Req.Test.html(conn, File.read!(@bing_fixture))
    end)

    assert {:ok, %Words.Entry{word: "hello", source: :bing}} =
             Words.lookup("hello", provider: :bing)
  end

  test "trims the word before dispatching" do
    Req.Test.stub(Words.Providers.HTTP, fn conn ->
      assert conn.query_string =~ "q=hello"
      Req.Test.html(conn, File.read!(@bing_fixture))
    end)

    assert {:ok, %Words.Entry{word: "hello"}} = Words.lookup("  hello  ")
  end

  test "propagates HTTP errors from the source" do
    Req.Test.stub(Words.Providers.HTTP, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:http_error, 500}} = Words.lookup("hello", provider: :bing)
  end

  test "maps a Longman 404 to not_found" do
    Req.Test.stub(Words.Providers.HTTP, fn conn ->
      Plug.Conn.send_resp(conn, 404, "spellcheck")
    end)

    assert {:error, :not_found} = Words.lookup("qwzzz", provider: :longman)
  end

  describe "lookup_all/1" do
    test "queries every provider and keys results by name" do
      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        Req.Test.html(conn, fixture_html(conn.host))
      end)

      results = Words.lookup_all("hello")

      assert map_size(results) == 5

      for source <- [:bing, :collins, :eudic, :longman, :youdao] do
        assert {:ok, %Words.Entry{word: "hello", source: ^source}} = results[source]
      end
    end

    test "reports per-provider failures as data" do
      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      results = Words.lookup_all("hello")

      assert map_size(results) == 5
      assert Enum.all?(results, fn {_name, result} -> result == {:error, {:http_error, 500}} end)
    end

    test "rejects blank input for every provider without network calls" do
      results = Words.lookup_all("   ")

      assert map_size(results) == 5
      assert Enum.all?(results, fn {_name, result} -> result == {:error, :empty_word} end)
    end

    # the provider crash below is intentional; keep its log out of the output
    @tag capture_log: true
    test "isolates a crashing provider from the others" do
      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        case conn.host do
          "cn.bing.com" -> raise "bing exploded"
          host -> Req.Test.html(conn, fixture_html(host))
        end
      end)

      results = Words.lookup_all("hello")

      assert {:error, {:task_exit, _reason}} = results.bing

      for source <- [:collins, :eudic, :longman, :youdao] do
        assert {:ok, %Words.Entry{source: ^source}} = results[source]
      end
    end

    test "kills a provider that exceeds the timeout and keeps the rest" do
      Application.put_env(:words, :lookup_all_timeout, 50)
      on_exit(fn -> Application.delete_env(:words, :lookup_all_timeout) end)

      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        if conn.host == "cn.bing.com", do: Process.sleep(200)
        Req.Test.html(conn, fixture_html(conn.host))
      end)

      results = Words.lookup_all("hello")

      assert results.bing == {:error, {:task_exit, :timeout}}

      for source <- [:collins, :eudic, :longman, :youdao] do
        assert {:ok, %Words.Entry{source: ^source}} = results[source]
      end
    end
  end

  defp fixture_html(host) do
    fixture =
      case host do
        "cn.bing.com" -> "bing_hello.html"
        "dict.eudic.net" -> "eudic_hello.html"
        "www.ldoceonline.com" -> "longman_hello.html"
        # Collins and Youdao parse different sections of this page
        "dict.youdao.com" -> "youdao_hello.html"
      end

    File.read!(Path.expand("fixtures/#{fixture}", __DIR__))
  end
end
