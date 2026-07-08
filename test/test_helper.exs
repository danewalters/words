# Route all provider HTTP calls to Req.Test stubs instead of the network.
# Tests that exercise lookup/1 must register a stub named
# Words.Providers.HTTP; parse-only tests are unaffected.
Application.put_env(:words, :req_options, plug: {Req.Test, Words.Providers.HTTP})

# The cache is global named-ETS state: with it enabled, one async test's
# lookup would leak results into another's. Disabled by default;
# Words.CacheTest (async: false) re-enables it per test.
Application.put_env(:words, :cache, enabled: false)

ExUnit.start()
