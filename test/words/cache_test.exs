defmodule Words.CacheTest do
  # The cache is global named-ETS state plus global config, so these
  # tests must not run concurrently with anything else.
  use ExUnit.Case, async: false

  alias Words.Cache

  @bing_fixture Path.expand("../fixtures/bing_hello.html", __DIR__)

  setup do
    configure(enabled: true)
    Cache.flush()
    on_exit(fn -> Application.put_env(:words, :cache, enabled: false) end)
    :ok
  end

  defp configure(opts) do
    defaults = [enabled: true, max_entries: 100, ttl: 60_000, negative_ttl: 60_000]
    Application.put_env(:words, :cache, Keyword.merge(defaults, opts))
  end

  # put/3 and promotion are casts; a synchronous call forces the cache
  # process to have drained everything queued before it.
  defp await_writes, do: :sys.get_state(Cache)

  describe "get/2 and put/3" do
    test "returns a stored ok result" do
      Cache.put(:bing, "hello", {:ok, :entry})
      await_writes()

      assert {:hit, {:ok, :entry}} = Cache.get(:bing, "hello")
    end

    test "keys entries by provider as well as word" do
      Cache.put(:bing, "hello", {:ok, :bing_entry})
      await_writes()

      assert {:hit, {:ok, :bing_entry}} = Cache.get(:bing, "hello")
      assert :miss = Cache.get(:youdao, "hello")
    end

    test "expires entries after the ttl" do
      configure(ttl: 30)

      Cache.put(:bing, "hello", {:ok, :entry})
      await_writes()
      assert {:hit, _} = Cache.get(:bing, "hello")

      Process.sleep(40)
      assert :miss = Cache.get(:bing, "hello")
    end

    test "negative-caches not_found with its own ttl" do
      configure(negative_ttl: 30)

      Cache.put(:bing, "zzzzz", {:error, :not_found})
      await_writes()
      assert {:hit, {:error, :not_found}} = Cache.get(:bing, "zzzzz")

      Process.sleep(40)
      assert :miss = Cache.get(:bing, "zzzzz")
    end

    test "never caches transient failures" do
      Cache.put(:bing, "a", {:error, {:http_error, 500}})
      Cache.put(:bing, "b", {:error, {:task_exit, :timeout}})
      Cache.put(:bing, "c", {:error, :some_transport_error})
      await_writes()

      assert :miss = Cache.get(:bing, "a")
      assert :miss = Cache.get(:bing, "b")
      assert :miss = Cache.get(:bing, "c")
    end
  end

  describe "generational rotation" do
    test "evicts the untouched generation, keeps what was read" do
      configure(max_entries: 2)

      Cache.put(:bing, "a", {:ok, :a})
      Cache.put(:bing, "b", {:ok, :b})
      # new is full: this rotates {a, b} into old and starts new with c
      Cache.put(:bing, "c", {:ok, :c})
      await_writes()

      # everything is still reachable after one rotation
      assert {:hit, _} = Cache.get(:bing, "a")
      # ...and reading "a" promoted it into the new generation
      await_writes()

      # second rotation: drops the old generation, where b sat untouched
      Cache.put(:bing, "d", {:ok, :d})
      await_writes()

      assert {:hit, _} = Cache.get(:bing, "a")
      assert {:hit, _} = Cache.get(:bing, "c")
      assert {:hit, _} = Cache.get(:bing, "d")
      assert :miss = Cache.get(:bing, "b")
    end
  end

  describe "facade integration" do
    test "serves repeat lookups from the cache" do
      test_pid = self()

      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        send(test_pid, :http_request)
        Req.Test.html(conn, File.read!(@bing_fixture))
      end)

      assert {:ok, %Words.Entry{word: "hello"}} = Words.lookup("hello", provider: :bing)
      assert_received :http_request
      await_writes()

      assert {:ok, %Words.Entry{word: "hello"}} = Words.lookup("hello", provider: :bing)
      refute_received :http_request
    end

    test "always fetches fresh when disabled" do
      configure(enabled: false)
      test_pid = self()

      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        send(test_pid, :http_request)
        Req.Test.html(conn, File.read!(@bing_fixture))
      end)

      assert {:ok, _} = Words.lookup("hello", provider: :bing)
      assert {:ok, _} = Words.lookup("hello", provider: :bing)

      assert_received :http_request
      assert_received :http_request
    end

    test "lookup_all shares the same cache" do
      test_pid = self()

      Req.Test.stub(Words.Providers.HTTP, fn conn ->
        send(test_pid, {:http_request, conn.host})
        Req.Test.html(conn, File.read!(@bing_fixture))
      end)

      # warm the cache for bing through the single-provider path
      assert {:ok, _} = Words.lookup("hello", provider: :bing)
      assert_received {:http_request, "cn.bing.com"}
      await_writes()

      # the concurrent path must not refetch bing
      Words.lookup_all("hello")
      refute_received {:http_request, "cn.bing.com"}
    end
  end
end
