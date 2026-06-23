-- server.lua — vim.uv TCP server: bind (with port auto-increment), accept,
-- async HTTP request parse (chunked), routing, and response writing.
-- 100% async libuv I/O; no *Sync calls in any request path.
local uv = vim.uv or vim.loop
local static = require("liz-live-server.static")
local inject = require("liz-live-server.inject")
local sse = require("liz-live-server.sse")

local M = {}

-- Cap on accumulated header bytes -> 431. 32 KB is far above any legitimate
-- browser request line + headers (typically < 8 KB); the cap bounds buffering
-- from a malformed/hostile client that never sends CRLFCRLF.
local MAX_HEADER = 32 * 1024

local REASON = {
  [200] = "OK",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
}

-- ── low-level socket helpers ────────────────────────────────────────────────

local function close_client(client)
  if client and not client:is_closing() then
    client:close()
  end
end

--- Write a payload then close the connection (connection-per-request).
local function write_close(client, payload)
  if not client or client:is_closing() then
    return
  end
  client:write(payload, function()
    close_client(client)
  end)
end

--- Build an HTTP response. Body is omitted on HEAD, but Content-Length always
--- reflects the (post-injection) body size so HEAD headers match GET.
---@param code integer
---@param mime string
---@param body string
---@param is_head boolean
---@param extra string[]|nil extra header lines
---@return string
local function build_response(code, mime, body, is_head, extra)
  local lines = {
    ("HTTP/1.1 %d %s"):format(code, REASON[code] or "Unknown"),
    "Content-Type: " .. mime,
    "Cache-Control: no-cache, no-store, must-revalidate",
    "Content-Length: " .. tostring(#body),
    "Connection: close",
  }
  if extra then
    for _, h in ipairs(extra) do
      lines[#lines + 1] = h
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  local head = table.concat(lines, "\r\n")
  if is_head then
    return head
  end
  return head .. body
end

--- Send a minimal HTML error page.
local function send_error(client, code, is_head)
  local body = ("<!doctype html><meta charset=utf-8><title>%d %s</title><h1>%d %s</h1>"):format(
    code,
    REASON[code] or "Error",
    code,
    REASON[code] or "Error"
  )
  local extra = code == 405 and { "Allow: GET, HEAD" } or nil
  write_close(client, build_response(code, "text/html; charset=utf-8", body, is_head, extra))
end

--- Serve a known file path: read, MIME, inject reload script into HTML, write.
local function serve_file(client, path, is_head)
  static.read(path, function(err, data)
    if err or not data then
      return send_error(client, 500, is_head)
    end
    local mime = static.mime(path)
    local body = data
    if static.is_html(mime) then
      body = inject.html(body)
    end
    write_close(client, build_response(200, mime, body, is_head))
  end)
end

--- Serve a resolved directory: index.html if present, else generated listing
--- (both get the reload script injected so the page live-reloads).
local function serve_dir(client, dirpath, target, is_head)
  local index_path = static.strip_sep(dirpath) .. "/index.html"
  uv.fs_stat(index_path, function(serr, st)
    if not serr and st and st.type == "file" then
      return serve_file(client, index_path, is_head)
    end
    static.listing_html(dirpath, target, function(lerr, html)
      if lerr or not html then
        return send_error(client, 500, is_head)
      end
      write_close(client, build_response(200, "text/html; charset=utf-8", inject.html(html), is_head))
    end)
  end)
end

-- ── request handling ────────────────────────────────────────────────────────

--- Route a fully-parsed request.
---@param state table
---@param client userdata
---@param method string
---@param target string raw request target (path + optional query)
local function route(state, client, method, target)
  local is_head = method == "HEAD"
  if method ~= "GET" and method ~= "HEAD" then
    return send_error(client, 405, is_head)
  end

  local path = target:gsub("[?#].*$", "")

  -- SSE stream (GET only; held open). HEAD just gets the stream headers + close.
  if path == inject.SSE_PATH then
    if is_head then
      return write_close(
        client,
        build_response(200, "text/event-stream; charset=utf-8", "", true)
      )
    end
    return sse.handle(state, client)
  end

  -- Reload client JS route.
  if path == inject.CLIENT_JS_PATH then
    return write_close(
      client,
      build_response(200, "application/javascript; charset=utf-8", inject.client_js, is_head)
    )
  end

  -- Static file / directory under root.
  static.resolve(state.root, target, function(status, info)
    if status then
      return send_error(client, status, is_head)
    end
    if info.is_dir then
      serve_dir(client, info.path, target, is_head)
    else
      serve_file(client, info.path, is_head)
    end
  end)
end

--- Read + accumulate a single connection's request until CRLFCRLF, then route.
local function serve_connection(state, client)
  local req_buf = ""
  local done = false
  client:read_start(function(err, chunk)
    if err or not chunk then
      -- read error or EOF before headers complete
      if not done then
        close_client(client)
      end
      return
    end
    if done then
      return -- ignore trailing/pipelined bytes (Connection: close, no body)
    end
    req_buf = req_buf .. chunk
    local he = req_buf:find("\r\n\r\n", 1, true)
    if not he then
      if #req_buf > MAX_HEADER then
        done = true
        client:read_stop()
        send_error(client, 431, false)
      end
      return
    end
    done = true
    client:read_stop()
    local head = req_buf:sub(1, he - 1)
    local first = head:match("^(.-)\r\n") or head
    local method, target = first:match("^(%u+)%s+(%S+)")
    if not method or not target then
      return send_error(client, 405, false)
    end
    route(state, client, method, target)
  end)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Try to bind+listen on one host:port. Returns the server handle or nil,err.
local function bind_listen(host, port, on_conn)
  local server = uv.new_tcp()
  local ok, err = pcall(function()
    assert(server:bind(host, port))
    assert(server:listen(128, on_conn))
  end)
  if not ok then
    if not server:is_closing() then
      server:close()
    end
    return nil, tostring(err)
  end
  return server
end

--- Start the server, auto-incrementing the port on collisions.
--- On success sets state.server and state.port. Returns (true) or (false, err).
---@param state table runtime state singleton (uses state.root)
---@param opts table config options (host, port, max_port_tries)
---@return boolean ok
---@return string|nil err
function M.start(state, opts)
  local on_conn = function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    if not client then
      return -- allocation failure; drop this connection rather than accept(nil)
    end
    state.server:accept(client)
    serve_connection(state, client)
  end

  local last_err
  for i = 0, (opts.max_port_tries - 1) do
    local port = opts.port + i
    local server, err = bind_listen(opts.host, port, on_conn)
    if server then
      state.server = server
      state.port = port
      return true
    end
    last_err = err
    -- Only keep trying on "address in use"; other errors are fatal.
    if not (err and err:find("EADDRINUSE")) then
      break
    end
  end
  return false, last_err or "bind failed"
end

--- Stop the server: close the listen handle. (SSE clients are closed by sse.)
---@param state table
function M.stop(state)
  if state.server and not state.server:is_closing() then
    state.server:close()
  end
  state.server = nil
end

return M
