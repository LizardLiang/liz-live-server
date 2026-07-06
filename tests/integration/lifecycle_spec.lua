-- Integration: port auto-increment, start/stop/toggle, notify, open_current
-- navigation, no-leak.
-- TC-I08, TC-I12, TC-I13, TC-I18
local H = require("tests.helpers")
local fresh_liz = H.fresh_liz

describe("port auto-increment (TC-I08)", function()
  it("binds the next free port when the chosen one is busy", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local p = H.free_port(8200)
    local occupier = H.occupy(p)
    local liz = fresh_liz(root, { port = p, max_port_tries = 50 })
    liz.start()
    local st = liz.status()
    assert.is_true(st.running)
    assert.is_true(st.port > p) -- incremented past the busy port
    -- server actually responds on the reported port
    local r = H.request(st.port, "GET", "/index.html")
    assert.equals("200", H.status(r))
    liz.stop()
    occupier:close()
  end)
end)

describe("start/stop/toggle lifecycle (TC-I12)", function()
  it("transitions cleanly and frees the port on stop", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local p = H.free_port(8300)
    local liz = fresh_liz(root, { port = p })
    liz.start()
    assert.is_true(liz.status().running)
    local bound = liz.status().port
    liz.stop()
    assert.is_false(liz.status().running)
    assert.is_nil(liz.state.port)
    -- port is freed: we can bind it ourselves now
    local s = H.occupy(bound)
    assert.is_not_nil(s)
    s:close()
  end)

  it("toggle flips state", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8350) })
    liz.toggle()
    assert.is_true(liz.status().running)
    liz.toggle()
    assert.is_false(liz.status().running)
  end)

  it("start while running is idempotent (no second server)", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8360) })
    liz.start()
    local port1 = liz.status().port
    liz.start() -- should no-op
    assert.equals(port1, liz.status().port)
    liz.stop()
  end)
end)

describe("lifecycle notifications (TC-I13)", function()
  it("notifies on start, stop, and error", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m, lvl) ---@diagnostic disable-line: duplicate-set-field
      msgs[#msgs + 1] = { msg = m, level = lvl }
    end

    local ok, err = pcall(function()
      -- success path
      local p = H.free_port(8400)
      local liz = fresh_liz(root, { port = p })
      liz.start()
      vim.wait(500, function()
        for _, e in ipairs(msgs) do
          if e.msg:find("serving", 1, true) then
            return true
          end
        end
        return false
      end, 10)
      liz.stop()
      vim.wait(500, function()
        for _, e in ipairs(msgs) do
          if e.msg:find("stopped", 1, true) then
            return true
          end
        end
        return false
      end, 10)

      -- failure path: no free port
      local q = H.free_port(8450)
      local occ = H.occupy(q)
      local liz2 = fresh_liz(root, { port = q, max_port_tries = 1 })
      liz2.start()
      vim.wait(500, function()
        for _, e in ipairs(msgs) do
          if e.level == vim.log.levels.ERROR then
            return true
          end
        end
        return false
      end, 10)
      occ:close()
    end)

    vim.notify = orig
    assert.is_true(ok, tostring(err))

    local function any(pred)
      for _, e in ipairs(msgs) do
        if pred(e) then
          return true
        end
      end
      return false
    end
    assert.is_true(any(function(e)
      return e.msg:find("serving", 1, true) and e.msg:find("http://", 1, true)
    end))
    assert.is_true(any(function(e)
      return e.msg:find("stopped", 1, true)
    end))
    assert.is_true(any(function(e)
      return e.level == vim.log.levels.ERROR
    end))
  end)
end)

describe("non-loopback host warning (FR-009)", function()
  it("warns when host is not a loopback address", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local warned = false
    local orig = vim.notify
    vim.notify = function(m, lvl) ---@diagnostic disable-line: duplicate-set-field
      if lvl == vim.log.levels.WARN and tostring(m):find("non%-loopback") then
        warned = true
      end
    end
    local ok, err = pcall(function()
      -- TEST-NET-1 (192.0.2.0/24, RFC 5737): non-loopback and not assigned to
      -- the host, so bind fails fast — but the warning fires before bind, which
      -- is exactly what we assert (without actually exposing a socket).
      local liz = fresh_liz(root, { host = "192.0.2.1", port = H.free_port(8550), max_port_tries = 1 })
      liz.start()
      vim.wait(300, function()
        return warned
      end, 10)
      liz.stop()
    end)
    vim.notify = orig
    assert.is_true(ok, tostring(err))
    assert.is_true(warned)
  end)
end)

describe("open_current (navigate-current-buffer delta)", function()
  local function connect_and_wait_for_client(liz)
    liz.start()
    local port = liz.status().port
    local stream = H.sse_connect(port)
    vim.wait(1000, function()
      return liz.status().clients >= 1
    end, 5)
    return stream
  end

  it("starts the server when stopped, opening the current buffer's page", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>", ["A.html"] = "<body>a</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8900), open = false })
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/A.html"))
    assert.is_false(liz.status().running)
    liz.open_current()
    assert.is_true(liz.status().running)
    liz.stop()
  end)

  it("steers an already-connected tab via SSE navigate, without restarting", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>", ["B.html"] = "<body>b</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8910), open = false })
    local stream = connect_and_wait_for_client(liz)

    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/B.html"))
    liz.open_current()

    assert.is_true(stream:wait_for("data: navigate:/B.html", 1000))
    assert.is_true(liz.status().running) -- no restart / no new server
    stream:close()
    liz.stop()
  end)

  it("navigates a connected tab to / for a non-previewable active buffer", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>", ["mod.lua"] = "return 1" })
    local liz = fresh_liz(root, { port = H.free_port(8920), open = false })
    local stream = connect_and_wait_for_client(liz)

    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/mod.lua"))
    liz.open_current()

    assert.is_true(stream:wait_for("data: navigate:/", 1000))
    stream:close()
    liz.stop()
  end)

  it("falls back to browser.open when no SSE clients are connected", function()
    local browser = require("liz-live-server.browser")
    local root = H.tmproot({ ["index.html"] = "<body>x</body>", ["B.html"] = "<body>b</body>" })
    local liz = fresh_liz(root, { port = H.free_port(8930), open = false })
    liz.start()
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/B.html"))

    local called_url
    local orig = browser.open
    browser.open = function(url) ---@diagnostic disable-line: duplicate-set-field
      called_url = url
    end

    assert.equals(0, liz.status().clients)
    liz.open_current()

    browser.open = orig
    assert.is_not_nil(called_url)
    assert.truthy(called_url:find("/B.html", 1, true))
    liz.stop()
  end)
end)

describe("no handle leak across restarts (TC-I18)", function()
  it("returns to a clean state after each stop, and double-stop is safe", function()
    local root = H.tmproot({ ["index.html"] = "<body>x</body>" })
    local p = H.free_port(8500)
    local liz = fresh_liz(root, { port = p })
    for _ = 1, 10 do
      liz.start()
      assert.is_true(liz.status().running)
      liz.stop()
      assert.is_nil(liz.state.server)
      assert.is_nil(liz.state.ping_timer)
      assert.is_nil(liz.state.debounce_timer)
      assert.equals(0, vim.tbl_count(liz.state.clients))
    end
    -- double stop is a no-op, not an error
    assert.has_no.errors(function()
      liz.stop()
    end)
  end)
end)
