-- Unit: mermaid.lua — download URL, cache location, the availability gate that
-- keeps a truncated file from ever being served, and the fetch itself.
-- Every fetch here runs over file:// so the suite never touches the network.
local config = require("liz-live-server.config")
local mermaid = require("liz-live-server.mermaid")

-- Comfortably past M.MIN_BYTES, so it reads as a plausible bundle.
local BIG = string.rep("/*mermaid*/", 20000)

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (d:gsub("\\", "/"))
end

local function tmpfile(name, bytes)
  local p = tmpdir() .. "/" .. name
  local f = assert(io.open(p, "wb"))
  f:write(bytes)
  f:close()
  return p
end

--- Absolute path -> file:// URL, on both POSIX ("/x") and Windows ("C:/x").
local function file_url(path)
  local p = path:gsub("\\", "/")
  return p:sub(1, 1) == "/" and ("file://" .. p) or ("file:///" .. p)
end

describe("mermaid.url", function()
  after_each(function()
    config.setup({})
  end)

  it("defaults to jsDelivr for the configured version", function()
    config.setup({})
    assert.equals("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js", mermaid.url())
  end)

  it("honors an exact version pin", function()
    config.setup({ mermaid = { version = "11.16.1" } })
    assert.equals("https://cdn.jsdelivr.net/npm/mermaid@11.16.1/dist/mermaid.min.js", mermaid.url())
  end)

  it("lets a full url override replace the version-built one", function()
    config.setup({ mermaid = { version = "11", url = "https://example.test/m.js" } })
    assert.equals("https://example.test/m.js", mermaid.url())
  end)

  it("merges into config without disturbing unrelated defaults", function()
    local o = config.setup({ mermaid = { version = "10" } })
    assert.equals("10", o.mermaid.version)
    assert.equals(5500, o.port)
    assert.equals("127.0.0.1", o.host)
  end)
end)

describe("mermaid cache", function()
  after_each(function()
    config.setup({})
    mermaid.forget()
  end)

  it("defaults to a plugin-owned file under stdpath('data')", function()
    config.setup({})
    local p = mermaid.cache_path()
    assert.truthy(p:find("/liz%-live%-server/mermaid%.min%.js$"))
    assert.truthy(p:find((vim.fn.stdpath("data"):gsub("\\", "/")), 1, true))
  end)

  it("reports unavailable when nothing is cached", function()
    config.setup({ mermaid = { cache_path = tmpdir() .. "/absent.js" } })
    mermaid.forget()
    assert.is_false(mermaid.is_available())
    assert.is_nil(mermaid.read())
  end)

  it("rejects a truncated file rather than serving it as the bundle", function()
    config.setup({ mermaid = { cache_path = tmpfile("mermaid.min.js", "404 Not Found") } })
    mermaid.forget()
    assert.is_false(mermaid.is_available())
    assert.is_nil(mermaid.read())
  end)

  it("reads a plausible bundle and memoizes it until forget()", function()
    local p = tmpfile("mermaid.min.js", BIG)
    config.setup({ mermaid = { cache_path = p } })
    mermaid.forget()
    assert.is_true(mermaid.is_available())
    assert.equals(BIG, mermaid.read())
    -- Memoized: the multi-MB body is not re-read off disk per page load.
    os.remove(p)
    assert.equals(BIG, mermaid.read())
    mermaid.forget()
    assert.is_nil(mermaid.read())
  end)
end)

describe("mermaid.fetch", function()
  local has_curl = vim.fn.executable("curl") == 1

  after_each(function()
    config.setup({})
    mermaid.forget()
  end)

  local function fetch_sync()
    local done, ok, detail = false, nil, nil
    mermaid.fetch(function(o, d)
      ok, detail, done = o, d, true
    end)
    vim.wait(30000, function()
      return done
    end, 20)
    return done, ok, detail
  end

  it("installs the download into the cache, creating the directory", function()
    if not has_curl then
      return -- no downloader on this box; the other specs still cover the gate
    end
    local src = tmpfile("upstream.js", BIG)
    local dest = tmpdir() .. "/nested/mermaid.min.js"
    config.setup({ mermaid = { url = file_url(src), cache_path = dest } })
    mermaid.forget()

    local done, ok = fetch_sync()
    assert.is_true(done)
    assert.is_true(ok)
    assert.is_true(mermaid.is_available())
    assert.equals(BIG, mermaid.read())
  end)

  it("refuses a truncated download and leaves the previous cache intact", function()
    if not has_curl then
      return
    end
    local cached = tmpfile("mermaid.min.js", BIG)
    local upstream = tmpfile("short.js", "oops")
    config.setup({ mermaid = { url = file_url(upstream), cache_path = cached } })
    mermaid.forget()

    local done, ok, detail = fetch_sync()
    assert.is_true(done)
    assert.is_false(ok)
    assert.truthy(detail:find("truncated", 1, true))
    -- The good copy the user already had must survive a bad fetch.
    assert.is_true(mermaid.is_available())
    assert.equals(BIG, mermaid.read())
  end)

  it("reports a failed download and caches nothing", function()
    if not has_curl then
      return
    end
    local dest = tmpdir() .. "/mermaid.min.js"
    config.setup({ mermaid = { url = file_url(tmpdir() .. "/does-not-exist.js"), cache_path = dest } })
    mermaid.forget()

    local done, ok, detail = fetch_sync()
    assert.is_true(done)
    assert.is_false(ok)
    assert.truthy(detail:find("download failed", 1, true))
    assert.is_false(mermaid.is_available())
  end)
end)
