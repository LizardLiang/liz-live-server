-- Unit: browser.compute_path — which URL the browser auto-opens on start.
-- Covers the bug fix: HTML *and* Markdown buffers under root open their own
-- page (not the directory), with prefix/percent-encoding handling.
local browser = require("liz-live-server.browser")
local H = require("tests.helpers")

local function open(root, rel)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. rel))
end

describe("browser.compute_path", function()
  it("opens an HTML buffer under root to its own page", function()
    local root = H.tmproot({ ["page.html"] = "<html></html>" })
    open(root, "page.html")
    assert.equals("/page.html", browser.compute_path(root))
  end)

  it("opens a Markdown buffer under root to its own page", function()
    local root = H.tmproot({ ["README.md"] = "# hi" })
    open(root, "README.md")
    assert.equals("/README.md", browser.compute_path(root))
  end)

  it("opens a .markdown buffer too", function()
    local root = H.tmproot({ ["doc.markdown"] = "# hi" })
    open(root, "doc.markdown")
    assert.equals("/doc.markdown", browser.compute_path(root))
  end)

  it("percent-encodes nested path segments", function()
    local root = H.tmproot({ ["a b/c.md"] = "x" })
    open(root, "a b/c.md")
    assert.equals("/a%20b/c.md", browser.compute_path(root))
  end)

  it("falls back to / for a non-previewable extension", function()
    local root = H.tmproot({ ["notes.txt"] = "x" })
    open(root, "notes.txt")
    assert.equals("/", browser.compute_path(root))
  end)

  it("falls back to / for an unnamed buffer", function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd("enew")
    local root = H.tmproot({})
    assert.equals("/", browser.compute_path(root))
  end)

  it("falls back to / for a file outside root", function()
    local root = H.tmproot({})
    local other = H.tmproot({ ["out.md"] = "x" })
    open(other, "out.md")
    assert.equals("/", browser.compute_path(root))
  end)
end)
