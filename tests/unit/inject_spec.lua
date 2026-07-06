-- Unit: inject.lua splice + client JS contract. TC-U06, TC-U07
local inject = require("liz-live-server.inject")

describe("inject.html (TC-U06)", function()
  it("splices before the first </body> (case-insensitive)", function()
    local out = inject.html("<html><body>x</body></html>")
    assert.truthy(out:find('<script src="/__liz_reload.js"></script></body>', 1, true))
  end)

  it("handles uppercase </BODY>", function()
    local out = inject.html("<HTML><BODY>x</BODY></HTML>")
    assert.truthy(out:find("__liz_reload.js", 1, true))
    -- script comes before the closing tag
    assert.is_true(out:find("__liz_reload.js", 1, true) < out:find("</BODY>", 1, true))
  end)

  it("appends when no </body> present", function()
    local out = inject.html("<p>no body tag</p>")
    assert.truthy(out:find("<p>no body tag</p>", 1, true))
    assert.truthy(out:find("__liz_reload.js", 1, true))
    assert.is_true(out:find("__liz_reload.js", 1, true) > out:find("</p>", 1, true))
  end)

  it("injects exactly one script tag", function()
    local out = inject.html("<body></body>")
    local _, count = out:gsub("__liz_reload%.js", "")
    assert.equals(1, count)
  end)

  it("targets the first of multiple </body>", function()
    local out = inject.html("<body>a</body><body>b</body>")
    local pos = out:find("__liz_reload.js", 1, true)
    local first_close = out:find("</body>", 1, true)
    assert.is_true(pos < first_close)
  end)
end)

describe("inject.client_js (TC-U07)", function()
  local js = inject.client_js

  it("opens an EventSource to the SSE path", function()
    assert.truthy(js:find("new EventSource", 1, true))
    assert.truthy(js:find("/__liz_reload", 1, true))
  end)

  it("reloads on the RELOAD_MSG event", function()
    assert.equals("reload", inject.RELOAD_MSG)
    assert.truthy(js:find("location.reload", 1, true))
    -- payload is injected from the shared constant (RELOAD_MSG var + %q value)
    assert.truthy(js:find("RELOAD_MSG", 1, true))
    assert.truthy(js:find('"' .. inject.RELOAD_MSG .. '"', 1, true))
    assert.truthy(js:find("e.data === RELOAD_MSG", 1, true))
  end)

  it("implements exponential backoff with a 10s cap", function()
    assert.truthy(js:find("* 2", 1, true))
    assert.truthy(js:find("10000", 1, true))
  end)

  it("shows a disconnected badge and resyncs on reconnect", function()
    assert.truthy(js:lower():find("disconnected", 1, true))
    assert.truthy(js:find("hadDisconnect", 1, true))
  end)

  it("navigates on a NAV_PREFIX-prefixed event instead of reloading", function()
    assert.equals("navigate:", inject.NAV_PREFIX)
    -- payload prefix is injected from the shared constant (NAV_PREFIX var + %q value)
    assert.truthy(js:find("NAV_PREFIX", 1, true))
    assert.truthy(js:find('"' .. inject.NAV_PREFIX .. '"', 1, true))
    assert.truthy(js:find("e.data.indexOf(NAV_PREFIX)", 1, true))
    assert.truthy(js:find("location.href", 1, true))
    assert.truthy(js:find("e.data.slice(NAV_PREFIX.length)", 1, true))
  end)
end)
