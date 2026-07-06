-- Integration: static serving, MIME, no-store fresh read, injection, dir/404.
-- TC-I01, TC-I02, TC-I03, TC-I04, TC-I05
local H = require("tests.helpers")

describe("static serving", function()
  it("serves index.html with 200 + html content-type (TC-I01)", function()
    H.with_server({ files = { ["index.html"] = "<html><body>hi</body></html>" } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/index.html")
      assert.equals("200", H.status(r))
      assert.is_true(H.has_header(r, "Content-Type: text/html"))
      assert.is_true(H.has_header(r, "Connection: close"))
      assert.truthy(H.body(r):find("hi", 1, true))
    end)
  end)

  it("serves assets by relative path with correct MIME, no injection (TC-I02)", function()
    H.with_server({
      files = {
        ["style.css"] = "body{color:red}",
        ["app.js"] = "console.log(1)",
        ["pic.svg"] = "<svg></svg>",
      },
    }, function(ctx)
      local css = H.request(ctx.port, "GET", "/style.css")
      assert.equals("200", H.status(css))
      assert.is_true(H.has_header(css, "Content-Type: text/css"))
      assert.is_false(H.body(css):find("__liz_reload", 1, true) ~= nil)

      local js = H.request(ctx.port, "GET", "/app.js")
      assert.is_true(H.has_header(js, "Content-Type: application/javascript"))

      local svg = H.request(ctx.port, "GET", "/pic.svg")
      assert.is_true(H.has_header(svg, "Content-Type: image/svg+xml"))
    end)
  end)

  it("sends no-store headers and reads fresh from disk (TC-I03)", function()
    H.with_server({ files = { ["index.html"] = "<body>v1</body>" } }, function(ctx)
      local r1 = H.request(ctx.port, "GET", "/index.html")
      assert.is_true(H.has_header(r1, "Cache-Control: no-cache, no-store, must-revalidate"))
      assert.truthy(H.body(r1):find("v1", 1, true))

      H.writefile(ctx.root .. "/index.html", "<body>v2</body>")
      local r2 = H.request(ctx.port, "GET", "/index.html")
      assert.truthy(H.body(r2):find("v2", 1, true))
      assert.is_false(H.body(r2):find("v1", 1, true) ~= nil)
    end)
  end)

  it("injects the reload script with matching Content-Length (TC-I04)", function()
    H.with_server({ files = { ["index.html"] = "<html><body>x</body></html>" } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/index.html")
      assert.truthy(H.body(r):find('<script src="/__liz_reload.js">', 1, true))
      local clen = tonumber(r:match("Content%-Length: (%d+)"))
      assert.equals(#H.body(r), clen)
    end)
  end)

  it("renders Markdown as live-reloading HTML, and serves the renderer JS", function()
    H.with_server({ files = { ["README.md"] = "# Title\n\nsome **text**." } }, function(ctx)
      local r = H.request(ctx.port, "GET", "/README.md")
      assert.equals("200", H.status(r))
      -- served as HTML, not raw text/markdown
      assert.is_true(H.has_header(r, "Content-Type: text/html"))
      local body = H.body(r)
      assert.truthy(body:find("window.__LIZ_MD", 1, true))
      assert.truthy(body:find("/__liz_md.js", 1, true))
      -- live-reload script is present so the page reloads on save
      assert.truthy(body:find("__liz_reload.js", 1, true))
      -- Content-Length matches the shell body
      local clen = tonumber(r:match("Content%-Length: (%d+)"))
      assert.equals(#body, clen)

      -- the renderer JS route serves JS
      local js = H.request(ctx.port, "GET", "/__liz_md.js")
      assert.equals("200", H.status(js))
      assert.is_true(H.has_header(js, "Content-Type: application/javascript"))
      assert.truthy(H.body(js):find("__liz_md_root", 1, true))
    end)
  end)

  it("directory: index, listing, and 404 (TC-I05)", function()
    H.with_server({
      files = {
        ["index.html"] = "<body>root</body>",
        ["sub/a.txt"] = "hello",
      },
    }, function(ctx)
      -- "/" serves index.html (injected)
      local root = H.request(ctx.port, "GET", "/")
      assert.equals("200", H.status(root))
      assert.truthy(H.body(root):find("root", 1, true))
      assert.truthy(H.body(root):find("__liz_reload", 1, true))

      -- "/sub/" has no index -> listing that lists a.txt and is injected
      local listing = H.request(ctx.port, "GET", "/sub/")
      assert.equals("200", H.status(listing))
      assert.truthy(H.body(listing):find("a.txt", 1, true))
      assert.truthy(H.body(listing):find("__liz_reload", 1, true))

      -- missing -> 404
      local miss = H.request(ctx.port, "GET", "/nope.html")
      assert.equals("404", H.status(miss))
    end)
  end)
end)
