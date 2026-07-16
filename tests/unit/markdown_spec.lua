-- Unit: markdown.lua — is_markdown detection, shell embedding + escaping, and
-- the first-party renderer JS contract.
local markdown = require("liz-live-server.markdown")
local inject = require("liz-live-server.inject")

describe("markdown.is_markdown", function()
  it("matches .md / .markdown case-insensitively", function()
    assert.is_true(markdown.is_markdown("/a/README.md"))
    assert.is_true(markdown.is_markdown("NOTES.MD"))
    assert.is_true(markdown.is_markdown("/x/doc.markdown"))
  end)

  it("rejects non-markdown", function()
    assert.is_false(markdown.is_markdown("/a/index.html"))
    assert.is_false(markdown.is_markdown("style.css"))
    assert.is_false(markdown.is_markdown("noext"))
  end)
end)

describe("markdown.shell", function()
  it("produces an html document that embeds the source + both scripts", function()
    local out = markdown.shell("# hi", "/README.md")
    assert.truthy(out:find("<!doctype html>", 1, true))
    assert.truthy(out:find("window.__LIZ_MD=", 1, true))
    -- renderer route and the live-reload script are both present
    assert.truthy(out:find(markdown.CLIENT_JS_PATH, 1, true))
    assert.truthy(out:find("__liz_reload.js", 1, true))
    -- reload script tag is exactly the shared one from inject
    assert.truthy(out:find(inject.script_tag, 1, true))
    -- title derived from basename
    assert.truthy(out:find("<title>README.md</title>", 1, true))
  end)

  -- The JSON literal sits between `window.__LIZ_MD=` and the shell's own
  -- `;</script>` closer. Because embed() escapes every "<" to <, the
  -- literal can never itself contain `;</script>`, so this capture is exact.
  local function embedded_json(out)
    return out:match("window%.__LIZ_MD=(.-);</script>")
  end

  it("neutralizes a literal </script> in the source (no breakout)", function()
    local out = markdown.shell("text </script><script>alert(1)</script> more", "/x.md")
    -- Shell emits exactly three legit </script> closers regardless of content;
    -- a breakout would push the count higher.
    local _, count = out:gsub("</script>", "")
    assert.equals(3, count)
    local json = embedded_json(out)
    assert.truthy(json)
    assert.is_nil(json:find("<", 1, true))
    assert.truthy(json:find("\\u003C/script", 1, true))
  end)

  it("escapes every < in the embedded source", function()
    local out = markdown.shell("<b>raw</b>", "/x.md")
    local json = embedded_json(out)
    assert.is_nil(json:find("<", 1, true))
    assert.truthy(json:find("\\u003Cb", 1, true))
  end)
end)

describe("markdown.client_js", function()
  local js = markdown.client_js

  it("reads the embedded source global", function()
    assert.truthy(js:find("window.__LIZ_MD", 1, true))
  end)

  it("renders into the shell mount node", function()
    assert.truthy(js:find("__liz_md_root", 1, true))
  end)

  it("ships a generic highlighter and inline/block rendering", function()
    assert.truthy(js:find("highlight", 1, true))
    assert.truthy(js:find("parseInline", 1, true))
    assert.truthy(js:find("<blockquote>", 1, true))
    assert.truthy(js:find("<table>", 1, true))
    assert.truthy(js:find("tok-keyword", 1, true))
  end)

  it("carries an inlined stylesheet with light/dark theming", function()
    assert.truthy(js:find("prefers-color-scheme", 1, true))
    -- the CSS placeholder was substituted (no template token remains)
    assert.is_nil(js:find("[==CSS==]", 1, true))
  end)

  it("renders HTML comments as ghost callouts instead of leaking markers", function()
    assert.truthy(js:find("liz-ghost-card", 1, true))
    assert.truthy(js:find("liz-ghost-inline", 1, true))
    assert.truthy(js:find("<!--", 1, true))
    assert.truthy(js:find("pre-wrap", 1, true))
    assert.truthy(js:find("💬", 1, true))
  end)
end)
