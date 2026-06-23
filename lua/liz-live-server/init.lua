-- init.lua — public API, runtime state singleton, and lifecycle orchestration.
local uv = vim.uv or vim.loop
local config = require("liz-live-server.config")
local server = require("liz-live-server.server")
local sse = require("liz-live-server.sse")
local watch = require("liz-live-server.watch")
local browser = require("liz-live-server.browser")
local inject = require("liz-live-server.inject")

local M = {}

-- Runtime state singleton (one server per Neovim session). See tech-spec §3.
M.state = {
  running = false,
  port = nil,
  host = "127.0.0.1",
  root = nil,
  server = nil,
  clients = {},
  watchers = {},
  watch_stopped = false, -- guard for in-flight Linux walk callbacks
  ping_timer = nil,
  debounce_timer = nil,
  error = nil,
}

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[liz-live-server] " .. msg, level or vim.log.levels.INFO)
  end)
end

--- Resolve and normalize the project root to an absolute path.
---@param root string|nil
---@return string
local function resolve_root(root)
  local r = root or vim.fn.getcwd()
  r = vim.fn.fnamemodify(r, ":p")
  return uv.fs_realpath(r) or r
end

--- Merge user options into config.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
end

--- Start the live server. No-op (with notice) if already running.
function M.start()
  local st = M.state
  if st.running then
    notify("already running at http://" .. st.host .. ":" .. tostring(st.port))
    return
  end

  local opts = config.options
  st.error = nil
  st.host = opts.host
  st.root = resolve_root(opts.root)
  st.clients = {}

  -- FR-009: localhost-only. A non-loopback host exposes the no-auth server
  -- off-host; honor the user's explicit choice but make the exposure visible.
  if not (st.host == "127.0.0.1" or st.host == "::1" or st.host == "localhost") then
    notify(
      ("host is %s (non-loopback): the server will be reachable off this machine"):format(st.host),
      vim.log.levels.WARN
    )
  end

  local ok, err = server.start(st, opts)
  if not ok then
    st.error = err or "failed to bind"
    notify("failed to start: " .. st.error, vim.log.levels.ERROR)
    return
  end

  st.running = true

  -- SSE keep-alive, and the watch -> debounce -> broadcast pipeline.
  sse.start_ping(st, opts.ping_ms)
  watch.start(st, opts, function()
    sse.broadcast(st, inject.RELOAD_MSG)
  end)

  local path = browser.compute_path(st.root)
  local url = browser.url(st.host, st.port, path)
  notify("serving " .. st.root .. " at " .. browser.url(st.host, st.port, "/"))
  if opts.open then
    browser.open(url)
  end
end

--- Stop the live server and tear down all handles.
function M.stop()
  local st = M.state
  if not st.running then
    return
  end
  watch.stop(st)
  sse.stop_ping(st)
  sse.close_all(st)
  server.stop(st)
  st.running = false
  st.port = nil
  st.error = nil
  notify("stopped")
end

--- Toggle the server on/off.
function M.toggle()
  if M.state.running then
    M.stop()
  else
    M.start()
  end
end

--- Machine-readable status (for scripting/tests).
---@return table { running, port, clients, error }
function M.status()
  return {
    running = M.state.running,
    port = M.state.port,
    clients = sse.count(M.state),
    error = M.state.error,
  }
end

--- lualine component (FR-023). Lazy-requires the component module to avoid a
--- require cycle.
function M.lualine_component(...)
  return require("liz-live-server.lualine")(...)
end

return M
