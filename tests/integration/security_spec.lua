-- Integration: root-jail traversal + symlink escape. TC-I06, TC-I17
local H = require("tests.helpers")
local uv = vim.uv or vim.loop

describe("path traversal jail (TC-I06)", function()
  it("never serves files outside root via ../", function()
    H.with_server({ files = { ["index.html"] = "<body>safe</body>" } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/../../../etc/passwd")
      local code = H.status(r)
      assert.is_true(code == "404" or code == "403")
      assert.is_false(H.body(r):find("root:", 1, true) ~= nil)
    end)
  end)

  it("blocks percent-encoded traversal", function()
    H.with_server({ files = { ["index.html"] = "<body>safe</body>" } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/%2e%2e/%2e%2e/secret")
      local code = H.status(r)
      assert.is_true(code == "404" or code == "403")
    end)
  end)
end)

describe("symlink escape (TC-I17)", function()
  it("returns 403 for a symlink pointing outside root (or skips if unsupported)", function()
    -- Build an outside dir with a secret, then a symlink inside root -> outside.
    local outside = H.tmproot({ ["secret.txt"] = "TOPSECRET" })
    H.with_server({ files = { ["index.html"] = "<body>x</body>" } }, function(ctx)
      local link = ctx.root .. "/escape"
      local ok = pcall(function()
        local r = uv.fs_symlink(outside, link, { dir = true })
        assert(r)
      end)
      if not ok then
        -- symlink creation not permitted (e.g. unprivileged Windows) -> skip
        return
      end
      local r = H.request(ctx.port, "GET", "/escape/secret.txt")
      local code = H.status(r)
      assert.is_true(code == "403" or code == "404")
      assert.is_false(H.body(r):find("TOPSECRET", 1, true) ~= nil)
    end)
  end)
end)
