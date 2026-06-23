-- E2E: full edit->reload workflow and bind-failure flow. TC-E01, TC-E02
local H = require("tests.helpers")
local fresh_liz = H.fresh_liz

describe("primary edit -> reload workflow (TC-E01)", function()
  it("serves injected page, reloads on save, closes SSE on stop", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<html><body>v1</body></html>" } }, function(ctx)
      -- 1) page is served with injection
      local page = H.request(ctx.port, "GET", "/index.html")
      assert.truthy(H.body(page):find("__liz_reload.js", 1, true))

      -- 2) open persistent SSE
      local stream = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)

      -- 3) edit file + fire save
      H.writefile(ctx.root .. "/index.html", "<html><body>v2</body></html>")
      local buf = vim.fn.bufadd(ctx.root .. "/index.html")
      vim.fn.bufload(buf)
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })

      -- 4) reload pushed
      assert.is_true(stream:wait_for("data: reload", 1000))

      -- 5) updated content now served
      local page2 = H.request(ctx.port, "GET", "/index.html")
      assert.truthy(H.body(page2):find("v2", 1, true))

      -- 6) stop closes the SSE socket
      ctx.liz.stop()
      local closed = vim.wait(1000, function()
        return stream:is_closed()
      end, 5)
      assert.is_true(closed)
      stream:close()
    end)
  end)
end)

describe("bind-failure flow (TC-E02)", function()
  it("does not start, sets error state + error notify + lualine token", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local p = H.free_port(8700)
    local occ = H.occupy(p)

    local got_error_notify = false
    local orig = vim.notify
    vim.notify = function(_, lvl) ---@diagnostic disable-line: duplicate-set-field
      if lvl == vim.log.levels.ERROR then
        got_error_notify = true
      end
    end

    local liz = fresh_liz(root, { port = p, max_port_tries = 1 })
    liz.start()
    vim.wait(500, function()
      return got_error_notify
    end, 10)
    vim.notify = orig

    assert.is_false(liz.status().running)
    assert.is_not_nil(liz.status().error)
    assert.is_true(got_error_notify)
    assert.truthy(liz.lualine_component():find("LiveServer: error", 1, true))

    occ:close()
  end)
end)
