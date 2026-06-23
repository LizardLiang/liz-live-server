-- sse.lua — /__liz_reload Server-Sent Events endpoint: open-client registry,
-- broadcast, keep-alive ping, and dead-handle cleanup.
-- Clients are stored as a set in `state.clients` keyed by the uv_tcp_t handle.
local uv = vim.uv or vim.loop

local M = {}

local SSE_HEADERS = table.concat({
  "HTTP/1.1 200 OK",
  "Content-Type: text/event-stream; charset=utf-8",
  "Cache-Control: no-cache, no-store, must-revalidate",
  "Connection: keep-alive",
  "X-Accel-Buffering: no", -- defeat proxy buffering of the stream
  "",
  "",
}, "\r\n")

--- Remove a client from the registry and close its handle.
---@param state table
---@param client userdata uv_tcp_t
local function drop(state, client)
  if state.clients[client] then
    state.clients[client] = nil
  end
  if client and not client:is_closing() then
    client:close()
  end
end

--- Write to one client; prune it on any write error.
---@param state table
---@param client userdata
---@param data string
local function write_or_drop(state, client, data)
  if not client or client:is_closing() then
    drop(state, client)
    return
  end
  client:write(data, function(err)
    if err then
      drop(state, client)
    end
  end)
end

--- Handle a GET /__liz_reload request: send the stream headers and register the
--- connection as an open client. The socket is held open (never closed here).
---@param state table
---@param client userdata uv_tcp_t accepted connection
function M.handle(state, client)
  client:write(SSE_HEADERS, function(err)
    if err then
      drop(state, client)
      return
    end
    state.clients[client] = true
  end)
end

--- Broadcast an event to every open client. `msg` is the SSE `data:` payload
--- (e.g. "reload"). Failed writes prune the client.
---@param state table
---@param msg string
function M.broadcast(state, msg)
  local frame = "data: " .. msg .. "\n\n"
  for client in pairs(state.clients) do
    write_or_drop(state, client, frame)
  end
end

--- Start the keep-alive ping timer. A comment frame every `ping_ms` both prunes
--- dead handles (failed write -> drop) and keeps EventSource from idling out.
---@param state table
---@param ping_ms integer
function M.start_ping(state, ping_ms)
  M.stop_ping(state)
  local timer = uv.new_timer()
  state.ping_timer = timer
  timer:start(ping_ms, ping_ms, function()
    for client in pairs(state.clients) do
      write_or_drop(state, client, ": ping\n\n")
    end
  end)
end

--- Stop the keep-alive ping timer.
---@param state table
function M.stop_ping(state)
  if state.ping_timer then
    state.ping_timer:stop()
    if not state.ping_timer:is_closing() then
      state.ping_timer:close()
    end
    state.ping_timer = nil
  end
end

--- Close every open client and clear the registry (used on stop/teardown).
---@param state table
function M.close_all(state)
  for client in pairs(state.clients) do
    if client and not client:is_closing() then
      client:close()
    end
  end
  state.clients = {}
end

--- Count of open SSE clients (FR-030).
---@param state table
---@return integer
function M.count(state)
  return vim.tbl_count(state.clients)
end

return M
