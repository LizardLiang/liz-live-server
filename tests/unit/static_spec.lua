-- Unit: static.lua pure logic (path jail, MIME, url enc/dec). TC-U01..U05
local static = require("liz-live-server.static")

describe("static.normalize_lexical (TC-U01)", function()
  it("drops '.' and resolves '..'", function()
    assert.equals("a/c", static.normalize_lexical("/a/b/../c"))
    assert.equals("a/b", static.normalize_lexical("/a/./b"))
  end)

  it("clamps '..' so it never escapes root", function()
    assert.equals("etc/passwd", static.normalize_lexical("/../../../etc/passwd"))
  end)

  it("normalizes root and empty to empty", function()
    assert.equals("", static.normalize_lexical("/"))
    assert.equals("", static.normalize_lexical(""))
  end)

  it("collapses double slashes and trailing slash", function()
    assert.equals("a", static.normalize_lexical("//a"))
    assert.equals("a/b", static.normalize_lexical("a/b/"))
  end)

  it("clamps backslash-separated traversal too (Windows-safe jail)", function()
    -- decoded form of /%2e%2e%5c%2e%2e%5cwin.ini
    assert.equals("win.ini", static.normalize_lexical("/..\\..\\win.ini"))
    assert.equals("a/b", static.normalize_lexical("a\\b"))
  end)
end)

describe("static.strip_sep (TC-U02)", function()
  it("strips trailing separators of either kind", function()
    assert.equals("/a/b", static.strip_sep("/a/b/"))
    assert.equals("C:\\a", static.strip_sep("C:\\a\\"))
    assert.equals("/a/b", static.strip_sep("/a/b"))
  end)
end)

describe("static.under_root (TC-U02)", function()
  it("accepts root itself and descendants", function()
    assert.is_true(static.under_root("/root", "/root"))
    assert.is_true(static.under_root("/root/x/y", "/root"))
  end)

  it("rejects sibling-prefix and unrelated paths", function()
    assert.is_false(static.under_root("/rootx", "/root"))
    assert.is_false(static.under_root("/other", "/root"))
  end)

  it("handles Windows separators", function()
    assert.is_true(static.under_root("C:\\root\\x", "C:\\root"))
    assert.is_false(static.under_root("C:\\rootx", "C:\\root"))
  end)

  it("normalizes extended-length prefixes on one side", function()
    -- fs_realpath may return \\?\ on Windows for one operand but not the other.
    assert.is_true(static.under_root("\\\\?\\C:\\root\\x", "C:\\root"))
    assert.is_true(static.under_root("C:\\root\\x", "\\\\?\\C:\\root"))
  end)

  it("matches case-insensitively only on Windows", function()
    local is_win = (vim.fn.has("win32") == 1) or (vim.fn.has("win64") == 1)
    if is_win then
      assert.is_true(static.under_root("C:\\Root\\X", "c:\\root"))
    else
      assert.is_false(static.under_root("/Root/x", "/root"))
    end
  end)
end)

describe("static.strip_ext_prefix", function()
  it("strips a leading //?/ prefix, leaves others alone", function()
    assert.equals("C:/root", static.strip_ext_prefix("//?/C:/root"))
    assert.equals("C:/root", static.strip_ext_prefix("C:/root"))
    assert.equals("/a/b", static.strip_ext_prefix("/a/b"))
  end)
end)

describe("static.mime (TC-U03)", function()
  it("maps known extensions", function()
    assert.truthy(static.mime("a.html"):find("text/html", 1, true))
    assert.truthy(static.mime("a.css"):find("text/css", 1, true))
    assert.truthy(static.mime("a.js"):find("application/javascript", 1, true))
    assert.truthy(static.mime("a.svg"):find("image/svg", 1, true))
  end)

  it("is case-insensitive on extension", function()
    assert.truthy(static.mime("INDEX.HTML"):find("text/html", 1, true))
  end)

  it("falls back to octet-stream", function()
    assert.equals("application/octet-stream", static.mime("a.xyz"))
    assert.equals("application/octet-stream", static.mime("noext"))
  end)
end)

describe("static.is_html (TC-U04)", function()
  it("detects html content types", function()
    assert.is_true(static.is_html("text/html; charset=utf-8"))
    assert.is_false(static.is_html("text/css; charset=utf-8"))
    assert.is_false(static.is_html("application/javascript"))
  end)
end)

describe("static url encode/decode (TC-U05)", function()
  it("decodes percent escapes", function()
    assert.equals("a b", static.url_decode("a%20b"))
    assert.equals("..", static.url_decode("%2e%2e"))
  end)

  it("encodes unsafe chars and preserves unreserved", function()
    assert.equals("a%20b", static.url_encode("a b"))
    assert.equals("a-_.~b", static.url_encode("a-_.~b"))
  end)
end)
