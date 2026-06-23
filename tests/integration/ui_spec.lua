-- Integration: lualine component, browser URL/open, async guarantees.
-- TC-I14, TC-I15, TC-I16
local H = require("tests.helpers")
local fresh_liz = H.fresh_liz

describe("lualine component (TC-I14)", function()
  it("is exposed and callable", function()
    local liz = fresh_liz(H.tmproot({}))
    assert.equals("function", type(liz.lualine_component))
  end)

  it("renders stopped / running / error states", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8600) })

    -- stopped -> empty
    assert.equals("", liz.lualine_component())

    -- running -> contains :port
    liz.start()
    local s = liz.lualine_component()
    assert.truthy(s:find(":" .. tostring(liz.status().port), 1, true))
    liz.stop()

    -- error -> text token
    liz.state.error = "boom"
    assert.truthy(liz.lualine_component():find("LiveServer: error", 1, true))
    liz.state.error = nil
  end)
end)

describe("browser URL computation + open opt-out (TC-I15)", function()
  it("returns the html file path for a servable buffer, else /", function()
    local browser = require("liz-live-server.browser")
    local root = H.tmproot({ ["page.html"] = "<body>p</body>", ["mod.lua"] = "return 1" })

    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/page.html"))
    assert.equals("/page.html", browser.compute_path(root))

    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/mod.lua"))
    assert.equals("/", browser.compute_path(root))

    vim.cmd("enew")
    assert.equals("/", browser.compute_path(root))
  end)

  it("builds a full url", function()
    local browser = require("liz-live-server.browser")
    assert.equals("http://127.0.0.1:5500/", browser.url("127.0.0.1", 5500, "/"))
    assert.equals("http://127.0.0.1:5500/a.html", browser.url("127.0.0.1", 5500, "/a.html"))
  end)

  it("does not open the browser when open=false", function()
    local browser = require("liz-live-server.browser")
    local called = false
    local orig = browser.open
    browser.open = function() ---@diagnostic disable-line: duplicate-set-field
      called = true
    end
    local liz = fresh_liz(H.tmproot({ ["index.html"] = "<body>x</body>" }), { port = H.free_port(8650), open = false })
    liz.start()
    liz.stop()
    browser.open = orig
    assert.is_false(called)
  end)

  it("opens the browser when open=true", function()
    local browser = require("liz-live-server.browser")
    local called = false
    local orig = browser.open
    browser.open = function() ---@diagnostic disable-line: duplicate-set-field
      called = true
    end
    local liz = fresh_liz(H.tmproot({ ["index.html"] = "<body>x</body>" }), { port = H.free_port(8660), open = true })
    liz.start()
    liz.stop()
    browser.open = orig
    assert.is_true(called)
  end)
end)

describe("async / no synchronous IO in request path (TC-I16)", function()
  it("contains no *Sync or vim.fn.system in the serving modules", function()
    for _, name in ipairs({ "server", "static", "sse" }) do
      local path = vim.api.nvim_get_runtime_file("lua/liz-live-server/" .. name .. ".lua", false)[1]
      assert.is_not_nil(path, "source for " .. name)
      local f = assert(io.open(path, "r"))
      local src = f:read("*a")
      f:close()
      -- strip comment lines so doc-comments mentioning the rule don't trip it
      local code = src:gsub("%-%-[^\n]*", "")
      assert.is_nil(code:match("fs_%w-Sync"), name .. " uses a *Sync fs call")
      assert.is_nil(code:match("vim%.fn%.system"), name .. " uses vim.fn.system")
    end
  end)

  it("serves many sequential requests without stalling", function()
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      for _ = 1, 20 do
        local r = H.request(ctx.port, "GET", "/index.html")
        assert.equals("200", H.status(r))
      end
    end)
  end)
end)
