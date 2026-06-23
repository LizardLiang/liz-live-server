-- browser.lua — open the served URL in the system browser.
-- Primary path is vim.ui.open (Neovim >= 0.10); per-OS jobstart is a fallback.
local uv = vim.uv or vim.loop
local static = require("liz-live-server.static")

local M = {}

--- Compute the request path to open: if the current buffer is a servable HTML
--- file under root, open that file; otherwise open the site root "/".
---@param root string
---@return string path
function M.compute_path(root)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return "/"
  end
  local real = uv.fs_realpath(file) or file
  if not static.under_root(real, root) then
    return "/"
  end
  local ext = real:match("%.([%w]+)$")
  if not ext or not (ext:lower() == "html" or ext:lower() == "htm") then
    return "/"
  end
  -- Build root-relative path with per-segment percent-encoding.
  local r = static.to_slash(real)
  local base = static.strip_sep(static.to_slash(root))
  local rel = r:sub(#base + 2) -- drop "base/"
  local parts = {}
  for seg in rel:gmatch("[^/]+") do
    parts[#parts + 1] = static.url_encode(seg)
  end
  return "/" .. table.concat(parts, "/")
end

--- Build the full http URL for a path.
---@param host string
---@param port integer
---@param path string
---@return string
function M.url(host, port, path)
  if not path or path == "" then
    path = "/"
  end
  return ("http://%s:%d%s"):format(host, port, path)
end

--- Open a URL in the system browser.
---@param url string
function M.open(url)
  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then
      return
    end
  end
  -- Fallback: per-OS launcher via jobstart (detached).
  local cmd
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    cmd = { "cmd", "/c", "start", "", url }
  elseif vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  else
    cmd = { "xdg-open", url }
  end
  pcall(vim.fn.jobstart, cmd, { detach = true })
end

return M
