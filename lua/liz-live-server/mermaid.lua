-- mermaid.lua — fetch-once local cache for the Mermaid diagram bundle.
--
-- Mermaid is ~3.5 MB of third-party JavaScript. That is too heavy to vendor in
-- a Lua plugin repo, and markdown.lua's renderer rule forbids pulling it from a
-- CDN at view time. So the user fetches it ONCE (`:LiveServerFetchMermaid`)
-- into stdpath("data"), and the server hands that cached copy to the browser
-- from the same local origin as every other asset. Until it is fetched,
-- ```mermaid fences stay ordinary highlighted code blocks: the preview never
-- breaks, and a page render never reaches the network.
local uv = vim.uv or vim.loop
local config = require("liz-live-server.config")

local M = {}

-- Route serving the cached bundle (referenced by markdown.lua's client JS).
M.CLIENT_JS_PATH = "/__liz_mermaid.js"

-- A truncated download or an HTML error page must never be served as the
-- bundle. The real minified file is several MB, so anything under this is a
-- failed fetch, not a smaller build.
M.MIN_BYTES = 100000

-- In-memory copy so repeat page loads don't re-read several MB off disk.
-- Cleared by M.forget() whenever the cache file is replaced.
local memo = nil

--- Effective `mermaid` option table (user config over defaults).
local function opts()
  local o = config.options or {}
  return o.mermaid or config.defaults.mermaid
end

--- Version specifier used to build the default download URL ("11", "11.16.1").
---@return string
function M.version()
  return opts().version or config.defaults.mermaid.version
end

--- Download URL: an explicit `mermaid.url` override, else the pinned jsDelivr
--- path for the configured version.
---@return string
function M.url()
  local u = opts().url
  if type(u) == "string" and u ~= "" then
    return u
  end
  return ("https://cdn.jsdelivr.net/npm/mermaid@%s/dist/mermaid.min.js"):format(M.version())
end

--- Absolute path of the cached bundle. Honors a `mermaid.cache_path` override.
---@return string
function M.cache_path()
  local p = opts().cache_path
  if type(p) == "string" and p ~= "" then
    return (vim.fn.fnamemodify(p, ":p"):gsub("\\", "/"))
  end
  return (vim.fn.stdpath("data"):gsub("\\", "/")) .. "/liz-live-server/mermaid.min.js"
end

--- True when a plausible bundle is already cached on disk. Stats only — never
--- reads the multi-MB body just to answer the question.
---@return boolean
function M.is_available()
  local st = uv.fs_stat(M.cache_path())
  return (st and st.type == "file" and st.size >= M.MIN_BYTES) and true or false
end

--- Drop the in-memory copy so the next M.read() re-reads from disk.
function M.forget()
  memo = nil
end

--- Read the cached bundle. Returns nil when absent or implausibly small, which
--- is what makes the JS route answer 404 and the page fall back to code blocks.
---@return string|nil bytes
function M.read()
  if memo then
    return memo
  end
  local fd = uv.fs_open(M.cache_path(), "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = (st and st.size and st.size > 0) and uv.fs_read(fd, st.size, 0) or nil
  uv.fs_close(fd)
  if not data or #data < M.MIN_BYTES then
    return nil
  end
  memo = data
  return memo
end

--- Pick an available downloader. curl ships with Windows 10+/macOS and most
--- Linux images; wget and PowerShell cover the rest.
---@param url string
---@param dest string
---@return string[]|nil argv
local function downloader(url, dest)
  if vim.fn.executable("curl") == 1 then
    return { "curl", "-fsSL", "--retry", "2", "-o", dest, url }
  end
  if vim.fn.executable("wget") == 1 then
    return { "wget", "-q", "-O", dest, url }
  end
  if vim.fn.has("win32") == 1 and vim.fn.executable("powershell") == 1 then
    return {
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      ("$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '%s' -OutFile '%s'"):format(
        url,
        dest
      ),
    }
  end
  return nil
end

--- Run argv, calling on_exit(code, output). Returns false if it never started.
---@param cmd string[]
---@param on_exit fun(code: integer, output: string)
---@return boolean started
local function run(cmd, on_exit)
  if vim.system then
    local ok = pcall(vim.system, cmd, { text = true }, function(res)
      on_exit(res.code or 1, (res.stderr or "") .. (res.stdout or ""))
    end)
    return ok
  end
  local buf = {}
  local ok, id = pcall(vim.fn.jobstart, cmd, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(buf, data)
      end
    end,
    on_exit = function(_, code)
      on_exit(code, table.concat(buf, "\n"))
    end,
  })
  return ok and type(id) == "number" and id > 0
end

--- Download the Mermaid bundle into the cache, replacing any previous copy.
--- Writes to a ".part" sibling and renames on success, so an interrupted or
--- truncated fetch can never leave a broken bundle where the route serves it.
---@param cb fun(ok: boolean, detail: string) called on the main loop
function M.fetch(cb)
  local dest = M.cache_path()
  local dir = dest:match("^(.*)/[^/]+$")
  local finish = function(ok, detail)
    vim.schedule(function()
      cb(ok, detail)
    end)
  end

  if dir then
    vim.fn.mkdir(dir, "p")
  end

  local tmp = dest .. ".part"
  uv.fs_unlink(tmp)

  local cmd = downloader(M.url(), tmp)
  if not cmd then
    return finish(false, "no downloader available (need curl, wget, or powershell)")
  end

  local started = run(cmd, function(code, output)
    if code ~= 0 then
      uv.fs_unlink(tmp)
      local tail = (output or ""):gsub("%s+$", "")
      return finish(false, ("download failed (exit %d)%s"):format(code, tail ~= "" and ": " .. tail or ""))
    end
    local st = uv.fs_stat(tmp)
    if not st or st.size < M.MIN_BYTES then
      uv.fs_unlink(tmp)
      return finish(false, "download looks truncated — existing cache left untouched")
    end
    uv.fs_unlink(dest) -- fs_rename won't clobber an existing file on Windows
    local ok, rerr = uv.fs_rename(tmp, dest)
    if not ok then
      uv.fs_unlink(tmp)
      return finish(false, "could not install bundle: " .. tostring(rerr))
    end
    M.forget()
    finish(true, ("%s (%.1f MB)"):format(dest, st.size / 1048576))
  end)

  if not started then
    finish(false, "could not start " .. cmd[1])
  end
end

return M
