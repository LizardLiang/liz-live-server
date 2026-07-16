-- static.lua — path resolution + root-jail, MIME map, directory listing, async file read.
-- All filesystem access is async (uv.fs_*); no *Sync calls in any path.
local uv = vim.uv or vim.loop

local M = {}

-- Windows filesystems are case-insensitive and libuv's fs_realpath can return an
-- extended-length "\\?\" prefix and/or a different drive-letter case than
-- getcwd/buffer names. Detected once at load (the OS never changes mid-session).
local IS_WINDOWS = (vim.fn.has("win32") == 1) or (vim.fn.has("win64") == 1)

-- Default mode for opened files (rw-r--r--). Lua has no octal literals.
local FILE_MODE_644 = tonumber("644", 8)

-- ── MIME ──────────────────────────────────────────────────────────────────
M.mime_types = {
  html = "text/html; charset=utf-8",
  htm = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8",
  js = "application/javascript; charset=utf-8",
  mjs = "application/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  map = "application/json; charset=utf-8",
  txt = "text/plain; charset=utf-8",
  md = "text/markdown; charset=utf-8",
  xml = "application/xml; charset=utf-8",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  ico = "image/x-icon",
  bmp = "image/bmp",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
  eot = "application/vnd.ms-fontobject",
  mp4 = "video/mp4",
  webm = "video/webm",
  ogg = "audio/ogg",
  mp3 = "audio/mpeg",
  wav = "audio/wav",
  pdf = "application/pdf",
  wasm = "application/wasm",
}

--- Resolve a MIME type from a file path; unknown -> octet-stream.
---@param path string
---@return string mime
function M.mime(path)
  local ext = path:match("%.([%w]+)$")
  if ext then
    ext = ext:lower()
    if M.mime_types[ext] then
      return M.mime_types[ext]
    end
  end
  return "application/octet-stream"
end

--- True if the MIME type is HTML (eligible for reload-script injection).
---@param mime string
---@return boolean
function M.is_html(mime)
  return mime:sub(1, 9) == "text/html"
end

-- ── Path helpers ──────────────────────────────────────────────────────────

--- Normalize separators to "/" for prefix comparison (Windows safe).
---@param p string
---@return string
local function to_slash(p)
  return (p:gsub("\\", "/"))
end
M.to_slash = to_slash

--- Strip trailing path separators (either slash kind). Shared so callers don't
--- re-inline the `[/\\]+$` gsub.
---@param p string
---@return string
function M.strip_sep(p)
  return (p:gsub("[/\\]+$", ""))
end

--- Percent-decode a URL path component.
---@param s string
---@return string
function M.url_decode(s)
  s = s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return s
end

--- Lexically normalize a URL path: split on "/", drop "." segments, pop on
--- "..", clamp "..": that would escape the root (never escapes). Pure string
--- work — no filesystem access. Returns the cleaned relative path (no leading
--- slash, "/" separators).
---@param urlpath string raw path (already query/fragment-stripped + decoded)
---@return string relpath
function M.normalize_lexical(urlpath)
  local parts = {}
  for seg in to_slash(urlpath):gmatch("[^/]+") do
    if seg == "." or seg == "" then
      -- skip
    elseif seg == ".." then
      if #parts > 0 then
        table.remove(parts)
      end
      -- else clamp: drop, never escape above root
    else
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

--- Strip a leading Windows extended-length prefix ("\\?\" -> "//?/" after
--- slash-normalization). Applied to both operands before a length-based slice
--- so the offsets line up regardless of whether fs_realpath added the prefix.
---@param p string already slash-normalized
---@return string
function M.strip_ext_prefix(p)
  return (p:gsub("^//%?/", ""))
end

--- Canonicalize a path for prefix comparison: normalize separators, strip any
--- extended-length prefix, strip trailing slashes, and (on Windows only)
--- lowercase — because the filesystem is case-insensitive there. Length is NOT
--- preserved (the prefix strip shortens), so callers slicing by length must use
--- strip_ext_prefix directly, not canon.
---@param p string
---@return string
local function canon(p)
  p = M.strip_ext_prefix(to_slash(p))
  p = p:gsub("/+$", "") -- strip trailing slashes
  if IS_WINDOWS then
    p = p:lower()
  end
  return p
end
M.canon = canon

--- True if `candidate` is `root` itself or lives under `root`. Comparison is
--- case-insensitive on Windows and prefix/separator-normalized, so a buffer
--- genuinely under root is never misclassified as outside it (and the security
--- jail is not bypassable via case-variant paths on a case-insensitive FS).
---@param candidate string
---@param root string
---@return boolean
function M.under_root(candidate, root)
  local c, r = canon(candidate), canon(root)
  if c == r then
    return true
  end
  return c:sub(1, #r + 1) == (r .. "/")
end

--- Resolve a URL path to a real file under `root` with the security jail
--- (tech-spec §5). Steps: strip query/fragment + decode; lexical normalize;
--- join to root; lexical prefix-check (403 on escape); fs_realpath (ENOENT ->
--- 404); post-realpath prefix-check (symlink escape -> 403); fs_stat.
---@param root string absolute, normalized project root
---@param urlpath string raw request target path
---@param cb fun(status:integer|nil, info:table|nil) info = { path, stat, is_dir }
function M.resolve(root, urlpath, cb)
  -- (1) strip query/fragment, then decode
  urlpath = urlpath:gsub("[?#].*$", "")
  urlpath = M.url_decode(urlpath)

  -- (2) lexical normalize
  local rel = M.normalize_lexical(urlpath)

  -- (3) join to root
  local sep = "/"
  local candidate = rel == "" and root or (to_slash(root):gsub("/+$", "") .. sep .. rel)

  -- (4) lexical prefix-check (before any fs call)
  if not M.under_root(candidate, root) then
    return cb(403, nil)
  end

  -- (5) realpath: ENOENT -> 404; else re-check prefix for symlink escape
  uv.fs_realpath(candidate, function(rerr, real)
    if rerr or not real then
      return cb(404, nil)
    end
    if not M.under_root(real, root) then
      return cb(403, nil) -- symlink escaped the jail
    end
    uv.fs_stat(real, function(serr, st)
      if serr or not st then
        return cb(404, nil)
      end
      cb(nil, { path = real, stat = st, is_dir = st.type == "directory" })
    end)
  end)
end

-- ── Async file read ─────────────────────────────────────────────────────────

--- Read an entire file asynchronously.
---@param path string
---@param cb fun(err:string|nil, data:string|nil)
function M.read(path, cb)
  uv.fs_open(path, "r", FILE_MODE_644, function(oerr, fd)
    if oerr or not fd then
      return cb(oerr or "open failed", nil)
    end
    uv.fs_fstat(fd, function(serr, st)
      if serr or not st then
        uv.fs_close(fd, function() end)
        return cb(serr or "fstat failed", nil)
      end
      local size = st.size
      if size == 0 then
        uv.fs_close(fd, function() end)
        return cb(nil, "")
      end
      -- libuv fs_read may return fewer bytes than requested (one read(2)); loop
      -- from an offset until the file is fully consumed or EOF, so large files
      -- are never silently truncated.
      local chunks = {}
      local offset = 0
      local function read_next()
        uv.fs_read(fd, size - offset, offset, function(rerr, data)
          if rerr then
            uv.fs_close(fd, function() end)
            return cb(rerr, nil)
          end
          if data and #data > 0 then
            chunks[#chunks + 1] = data
            offset = offset + #data
          end
          if not data or #data == 0 or offset >= size then
            uv.fs_close(fd, function() end)
            return cb(nil, table.concat(chunks))
          end
          read_next()
        end)
      end
      read_next()
    end)
  end)
end

-- ── Directory listing ───────────────────────────────────────────────────────

--- HTML-escape a string for safe embedding in the generated listing.
---@param s string
---@return string
local function esc(s)
  return (s:gsub("[&<>\"']", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
  }))
end

--- Generate a directory-listing HTML page for `dirpath`. `urlpath` is the
--- request path (used to build links and the heading); it is normalized to a
--- single trailing slash.
---@param dirpath string absolute directory path
---@param urlpath string request path, e.g. "/sub/"
---@param cb fun(err:string|nil, html:string|nil)
function M.listing_html(dirpath, urlpath, cb)
  uv.fs_scandir(dirpath, function(serr, handle)
    if serr or not handle then
      return cb(serr or "scandir failed", nil)
    end
    local base = "/" .. M.normalize_lexical(urlpath)
    if base ~= "/" then
      base = base .. "/"
    end
    local dirs, files = {}, {}
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" then
        dirs[#dirs + 1] = name
      else
        files[#files + 1] = name
      end
    end
    table.sort(dirs)
    table.sort(files)

    local rows = {}
    if base ~= "/" then
      rows[#rows + 1] = '<li><a href="../">../</a></li>'
    end
    for _, name in ipairs(dirs) do
      local href = base .. M.url_encode(name) .. "/"
      rows[#rows + 1] = ('<li><a href="%s">%s/</a></li>'):format(href, esc(name))
    end
    for _, name in ipairs(files) do
      local href = base .. M.url_encode(name)
      rows[#rows + 1] = ('<li><a href="%s">%s</a></li>'):format(href, esc(name))
    end

    local html = ([[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Index of %s</title>
<style>
:root{--fg:#222;--bg:#fff;--link:#0b66c3}
@media (prefers-color-scheme: dark){:root{--fg:#e6edf3;--bg:#0d1117;--link:#4493f8}}
body{font-family:system-ui,sans-serif;margin:2rem;color:var(--fg);background:var(--bg)}
h1{font-size:1.1rem;font-weight:600}
ul{list-style:none;padding:0;line-height:1.8}
a{text-decoration:none;color:var(--link)}
a:hover{text-decoration:underline}
</style>
</head>
<body>
<h1>Index of %s</h1>
<ul>
%s
</ul>
</body>
</html>
]]):format(esc(base), esc(base), table.concat(rows, "\n"))
    cb(nil, html)
  end)
end

--- Percent-encode a path segment for use in a generated link.
---@param s string
---@return string
function M.url_encode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

return M
