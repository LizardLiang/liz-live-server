-- Unit: config.lua deep-merge. TC-U08
describe("config.setup (TC-U08)", function()
  local config
  before_each(function()
    package.loaded["liz-live-server.config"] = nil
    config = require("liz-live-server.config")
  end)

  it("overrides a single option, preserving the rest", function()
    local o = config.setup({ port = 8080 })
    assert.equals(8080, o.port)
    assert.equals("127.0.0.1", o.host)
    assert.equals(true, o.open)
    assert.equals(50, o.debounce_ms)
  end)

  it("honors open=false", function()
    assert.equals(false, config.setup({ open = false }).open)
  end)

  it("returns defaults for nil opts", function()
    local o = config.setup(nil)
    assert.equals(config.defaults.port, o.port)
    assert.equals(config.defaults.host, o.host)
  end)

  it("overrides ignore_dirs list", function()
    local o = config.setup({ ignore_dirs = { "dist" } })
    assert.same({ "dist" }, o.ignore_dirs)
  end)
end)
