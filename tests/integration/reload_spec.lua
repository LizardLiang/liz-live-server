-- Integration: SSE registry/broadcast/client-js, debounce, BufWritePost.
-- TC-I09, TC-I10, TC-I11
local H = require("tests.helpers")
local uv = vim.uv or vim.loop

local function fire_bufwrite_for(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  return buf
end

describe("SSE transport (TC-I09)", function()
  it("serves the client JS route", function()
    local inject = require("liz-live-server.inject")
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/__liz_reload.js")
      assert.equals("200", H.status(r))
      assert.is_true(H.has_header(r, "Content-Type: application/javascript"))
      assert.truthy(H.body(r):find("new EventSource", 1, true))
      assert.equals(inject.client_js, H.body(r))
    end)
  end)

  it("registers a client and delivers a broadcast", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      local stream = H.sse_connect(ctx.port)
      local registered = vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)
      assert.is_true(registered)

      sse.broadcast(ctx.liz.state, "reload")
      assert.is_true(stream:wait_for("data: reload", 1000))
      stream:close()
    end)
  end)

  it("broadcasts to multiple clients", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      local a = H.sse_connect(ctx.port)
      local b = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 2
      end, 5)
      sse.broadcast(ctx.liz.state, "reload")
      assert.is_true(a:wait_for("data: reload", 1000))
      assert.is_true(b:wait_for("data: reload", 1000))
      a:close()
      b:close()
    end)
  end)
end)

describe("debounce coalescing (TC-I10)", function()
  it("collapses a burst of triggers into one reload", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<body>x</body>", ["a.html"] = "<body>a</body>" } }, function(ctx)
      local stream = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)

      local path = ctx.root .. "/a.html"
      for _ = 1, 5 do
        fire_bufwrite_for(path)
      end
      -- wait past debounce + delivery
      vim.wait(400, function()
        return false
      end, 20)

      local _, count = stream:text():gsub("data: reload", "")
      assert.equals(1, count)
      stream:close()
    end)
  end)
end)

describe("BufWritePost watch (TC-I11)", function()
  it("reloads on save of a file under root", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<body>x</body>", ["page.html"] = "<body>p</body>" } }, function(ctx)
      local stream = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)
      fire_bufwrite_for(ctx.root .. "/page.html")
      assert.is_true(stream:wait_for("data: reload", 1000))
      stream:close()
    end)
  end)

  it("does not reload on save of a file outside root", function()
    local sse = require("liz-live-server.sse")
    local outside = H.tmproot({ ["other.html"] = "<body>o</body>" })
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      local stream = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)
      fire_bufwrite_for(outside .. "/other.html")
      vim.wait(300, function()
        return false
      end, 20)
      local _, count = stream:text():gsub("data: reload", "")
      assert.equals(0, count)
      stream:close()
    end)
  end)
end)
