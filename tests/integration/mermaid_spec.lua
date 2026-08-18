-- Integration: the /__liz_mermaid.js route. It serves the fetch-once local
-- cache and nothing else — 404 until the user runs :LiveServerFetchMermaid,
-- 200 application/javascript afterwards. A Markdown page must never point the
-- browser at an external host either way.
local H = require("tests.helpers")
local mermaid = require("liz-live-server.mermaid")

local BIG = string.rep("/*mermaid*/", 20000)

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (d:gsub("\\", "/"))
end

describe("mermaid bundle route", function()
  after_each(function()
    mermaid.forget()
  end)

  it("404s while nothing is cached, so the page falls back to code blocks", function()
    local absent = tmpdir() .. "/absent.js"
    H.with_server({ config = { mermaid = { cache_path = absent } } }, function(ctx)
      mermaid.forget()
      local r = H.request(ctx.port, "GET", mermaid.CLIENT_JS_PATH)
      assert.equals("404", H.status(r))
    end)
  end)

  it("serves the cached bundle as javascript", function()
    local p = tmpdir() .. "/mermaid.min.js"
    H.writefile(p, BIG)
    H.with_server({ config = { mermaid = { cache_path = p } } }, function(ctx)
      mermaid.forget()
      local r = H.request(ctx.port, "GET", mermaid.CLIENT_JS_PATH)
      assert.equals("200", H.status(r))
      assert.is_true(H.has_header(r, "Content-Type: application/javascript; charset=utf-8"))
      assert.equals(BIG, H.body(r))
      -- HEAD advertises the same length without shipping several MB.
      local head = H.request(ctx.port, "HEAD", mermaid.CLIENT_JS_PATH)
      assert.equals(tostring(#BIG), head:match("Content%-Length: (%d+)"))
      assert.equals("", H.body(head))
    end)
  end)

  it("keeps a Markdown page free of external hosts", function()
    local files = { ["d.md"] = "# d\n\n```mermaid\ngraph TD;A-->B;\n```\n" }
    H.with_server({ files = files }, function(ctx)
      local shell = H.body(H.request(ctx.port, "GET", "/d.md"))
      assert.equals("200", H.status(H.request(ctx.port, "GET", "/d.md")))
      assert.is_nil(shell:find("http://", 1, true))
      assert.is_nil(shell:find("https://", 1, true))
      -- The renderer that pulls the bundle is itself served locally.
      local js = H.body(H.request(ctx.port, "GET", "/__liz_md.js"))
      assert.is_nil(js:find("cdn.jsdelivr.net", 1, true))
      assert.truthy(js:find(mermaid.CLIENT_JS_PATH, 1, true))
    end)
  end)
end)
