-- tests/helpers/init.lua — shared test utilities: temp roots, raw-TCP HTTP/SSE
-- clients, and a with_server wrapper that guarantees teardown.
local uv = vim.uv or vim.loop

local H = {}

--- Materialize a temp directory tree. `files` maps relative path -> content.
--- Directories implied by paths are created. Returns the absolute root.
---@param files table<string,string>
---@return string root
function H.tmproot(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  for rel, content in pairs(files or {}) do
    local full = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    local f = assert(io.open(full, "wb"))
    f:write(content)
    f:close()
  end
  return uv.fs_realpath(root) or root
end

--- Write/overwrite a single file under root (for fresh-read tests).
function H.writefile(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

--- Find a free TCP port at/above `base` by probing binds.
---@param base integer
---@return integer
function H.free_port(base)
  for p = base, base + 200 do
    local s = uv.new_tcp()
    local ok = pcall(function()
      assert(s:bind("127.0.0.1", p))
    end)
    s:close()
    if ok then
      return p
    end
  end
  error("no free port found from " .. base)
end

--- Occupy a port (returns the handle; caller must :close() it).
---@param port integer
---@return userdata
function H.occupy(port)
  local s = uv.new_tcp()
  assert(s:bind("127.0.0.1", port))
  s:listen(16, function() end)
  return s
end

--- Perform a single HTTP request over a raw TCP socket. Resolves the full
--- response text (headers + body) once the server closes the connection.
---@param port integer
---@param method string
---@param path string
---@param timeout_ms integer|nil
---@return string response, boolean ok
function H.request(port, method, path, timeout_ms)
  local client = uv.new_tcp()
  local buf = {}
  local done = false
  client:connect("127.0.0.1", port, function(err)
    if err then
      done = true
      return
    end
    client:write(method .. " " .. path .. " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        done = true
        return
      end
      buf[#buf + 1] = chunk
    end)
  end)
  local ok = vim.wait(timeout_ms or 2000, function()
    return done
  end, 5)
  if not client:is_closing() then
    client:close()
  end
  return table.concat(buf), ok
end

--- Send a raw request payload (for malformed/oversized header tests).
---@param port integer
---@param payload string
---@param timeout_ms integer|nil
---@return string response
function H.raw(port, payload, timeout_ms)
  local client = uv.new_tcp()
  local buf, done = {}, false
  client:connect("127.0.0.1", port, function(err)
    if err then
      done = true
      return
    end
    client:write(payload)
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        done = true
        return
      end
      buf[#buf + 1] = chunk
    end)
  end)
  vim.wait(timeout_ms or 2000, function()
    return done
  end, 5)
  if not client:is_closing() then
    client:close()
  end
  return table.concat(buf)
end

--- Open a persistent SSE connection. Returns a handle table with:
---   :received(substr) -> bool   (whether the stream so far contains substr)
---   :text() -> string
---   :close()
---@param port integer
---@return table
function H.sse_connect(port)
  local client = uv.new_tcp()
  local buf = {}
  local connected = false
  client:connect("127.0.0.1", port, function(err)
    if err then
      return
    end
    connected = true
    client:write("GET /__liz_reload HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        -- server closed the stream (or error): mirror by closing our handle so
        -- is_closed() reflects the disconnect.
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buf[#buf + 1] = chunk
    end)
  end)
  vim.wait(1000, function()
    return connected
  end, 5)
  return {
    text = function()
      return table.concat(buf)
    end,
    received = function(_, substr)
      return table.concat(buf):find(substr, 1, true) ~= nil
    end,
    wait_for = function(_, substr, ms)
      return vim.wait(ms or 1000, function()
        return table.concat(buf):find(substr, 1, true) ~= nil
      end, 5)
    end,
    is_closed = function()
      return client:is_closing()
    end,
    close = function()
      if not client:is_closing() then
        client:close()
      end
    end,
  }
end

--- Parse the status code from a raw HTTP response.
---@param resp string
---@return string|nil
function H.status(resp)
  return resp and resp:match("^HTTP/1%.1 (%d+)")
end

--- Extract the body (after the first CRLFCRLF).
---@param resp string
---@return string
function H.body(resp)
  return (resp:match("\r\n\r\n(.*)$")) or ""
end

--- True if the response has a given header line (case-insensitive name match
--- is not needed for our fixed-casing server, so this is a literal contains).
function H.has_header(resp, line)
  local head = resp:match("^(.-)\r\n\r\n") or resp
  return head:find(line, 1, true) ~= nil
end

--- Load a fresh copy of the plugin (reset module state) and configure it.
--- Shared by the lifecycle/ui/e2e specs that need finer control than with_server.
---@param root string
---@param cfg table|nil
---@return table liz
function H.fresh_liz(root, cfg)
  package.loaded["liz-live-server"] = nil
  local liz = require("liz-live-server")
  liz.setup(vim.tbl_extend("force", { root = root, open = false }, cfg or {}))
  return liz
end

--- Start a fresh server instance on a temp root and run fn(ctx), guaranteeing
--- stop() afterwards. ctx = { liz, port, root, status }.
--- opts: { files = {...}, config = {...}, no_start = bool }
---@param opts table
---@param fn fun(ctx:table)
function H.with_server(opts, fn)
  opts = opts or {}
  -- Fresh module state each call.
  package.loaded["liz-live-server"] = nil
  local liz = require("liz-live-server")
  local root = H.tmproot(opts.files or {})
  local base_port = H.free_port(opts.base_port or 8080)
  local cfg = vim.tbl_extend("force", { root = root, open = false, port = base_port }, opts.config or {})
  liz.setup(cfg)
  local ok_run, err
  local function run()
    local st = liz.status()
    ok_run, err = pcall(fn, { liz = liz, port = st.port, root = root, status = st })
  end
  if opts.no_start then
    ok_run, err = pcall(fn, { liz = liz, root = root })
  else
    liz.start()
    run()
  end
  pcall(liz.stop)
  if not ok_run then
    error(err)
  end
end

return H
