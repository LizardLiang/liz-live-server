-- watch.lua — file-change detection from BOTH sources merged through one
-- debounce: BufWritePost autocmd (universal floor) + uv.fs_event (external
-- changes). macOS/Windows use native recursive fs_event; Linux walks the tree
-- and watches per-directory (libuv has no recursive fs_event there).
local uv = vim.uv or vim.loop
local static = require("liz-live-server.static")

local M = {}

local AUGROUP = "LizLiveServer"

-- Linux walk safety valve: warn once if a project produces an unexpectedly
-- large number of per-directory watchers (e.g. a monorepo, or an ignore_dirs
-- gap). The watch still works; this just surfaces the cost.
local WATCHER_WARN_THRESHOLD = 1000

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[liz-live-server] " .. msg, level or vim.log.levels.WARN)
  end)
end

--- True on platforms where libuv supports recursive fs_event natively.
local function supports_recursive()
  return vim.fn.has("mac") == 1 or vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

--- Should this directory name be pruned from the Linux walk?
local function is_ignored(name, ignore_set)
  if name:sub(1, 1) == "." then
    return true -- dotted dirs (incl. .git)
  end
  return ignore_set[name] == true
end

-- Forward declaration (mutual recursion: walk -> add_watcher -> walk).
local walk

--- Add a non-recursive fs_event watcher on `dir`. On Linux a rename event may
--- signal a newly-created subdirectory, in which case we extend the walk.
--- No-ops if watching has been torn down (guards the async-callback race where
--- an in-flight walk fires after watch.stop()).
local function add_watcher(state, dir, opts, trigger)
  if state.watch_stopped or not state.watchers or not state.watchers.events then
    return
  end
  local h = uv.new_fs_event()
  if not h then
    return
  end
  local ok = pcall(function()
    h:start(dir, {}, function(err, filename, events)
      if err then
        return
      end
      local full = filename and (static.strip_sep(dir) .. "/" .. filename) or nil
      if filename and events and events.rename then
        uv.fs_stat(full, function(serr, st)
          if state.watch_stopped then
            return
          end
          if not serr and st and st.type == "directory" then
            walk(state, full, opts, trigger)
          end
        end)
      end
      trigger(full)
    end)
  end)
  -- Re-check the guard: stop() may have run during the synchronous start above.
  if ok and not state.watch_stopped and state.watchers and state.watchers.events then
    local events = state.watchers.events
    events[#events + 1] = h
    if #events == WATCHER_WARN_THRESHOLD then
      notify(
        ("watching %d directories; consider adding large dirs to ignore_dirs"):format(#events)
      )
    end
  elseif not h:is_closing() then
    h:close()
  end
end

--- Recursively walk `dir` (async) adding a watcher per directory, pruning
--- ignored/dotted directories to bound the watcher count.
walk = function(state, dir, opts, trigger)
  if state.watch_stopped then
    return
  end
  add_watcher(state, dir, opts, trigger)
  uv.fs_scandir(dir, function(err, handle)
    if err or not handle or state.watch_stopped then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" and not is_ignored(name, opts._ignore_set) then
        walk(state, static.strip_sep(dir) .. "/" .. name, opts, trigger)
      end
    end
  end)
end

--- Build the debounced trigger closure. Coalesces multi-chunk saves, formatter
--- re-saves, and the autocmd+fs_event double-fire into one reload (FR-011).
--- Accumulates changed-file identity across the debounce window: `path`
--- (absolute, real-pathed) is recorded per call; a call with no path (an
--- unattributable fs_event) marks the whole window unknown, which forces the
--- safe global-reload fallback on fire.
---@param state table
---@param opts table
---@param on_reload fun(changes:string[]|nil, unknown:boolean)
---@return fun(path:string|nil) trigger
local function make_trigger(state, opts, on_reload)
  state.pending_changes = {}
  state.pending_unknown = false
  return function(path)
    -- Guard against a late fs_event callback landing after watch.stop() has
    -- niled out pending_changes/pending_unknown (most reachable on Windows
    -- IOCP). Covers all four call sites uniformly (BufWritePost, win/mac
    -- recursive fs_event, Linux add_watcher, and the rename->walk
    -- continuation) instead of guarding each individually.
    if state.watch_stopped then
      return
    end
    if path then
      local real = uv.fs_realpath(path) or path
      state.pending_changes[real] = true
    else
      state.pending_unknown = true
    end

    local t = state.debounce_timer
    if not t then
      t = uv.new_timer()
      state.debounce_timer = t
    end
    t:stop()
    t:start(opts.debounce_ms, 0, function()
      local changes = {}
      for p in pairs(state.pending_changes) do
        changes[#changes + 1] = p
      end
      local unknown = state.pending_unknown
      state.pending_changes = {}
      state.pending_unknown = false
      on_reload(#changes > 0 and changes or nil, unknown)
    end)
  end
end

--- Start watching. `on_reload(changes, unknown)` is invoked (debounced) on any
--- detected change: `changes` is the deduped array of absolute real paths
--- accumulated over the debounce window (nil if none), and `unknown` is true
--- if any change in the window arrived without an identifiable path.
---@param state table runtime state (uses state.root; fills state.watchers, state.debounce_timer)
---@param opts table config (debounce_ms, ignore_dirs)
---@param on_reload fun(changes:string[]|nil, unknown:boolean)
function M.start(state, opts, on_reload)
  state.watchers = { events = {}, augroup = nil }
  state.watch_stopped = false

  local trigger = make_trigger(state, opts, on_reload)

  -- Source 1: BufWritePost for buffers whose resolved path is under root.
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  state.watchers.augroup = group
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local file = vim.api.nvim_buf_get_name(args.buf)
      if file == "" then
        return
      end
      local real = uv.fs_realpath(file) or file
      if static.under_root(real, state.root) then
        trigger(real)
      end
    end,
  })

  -- Source 2: fs_event.
  if supports_recursive() then
    local h = uv.new_fs_event()
    if h then
      local ok = pcall(function()
        h:start(state.root, { recursive = true }, function(err, filename)
          if err then
            return
          end
          if filename then
            trigger(static.strip_sep(state.root) .. "/" .. filename)
          else
            trigger(nil)
          end
        end)
      end)
      if ok then
        state.watchers.events[#state.watchers.events + 1] = h
      elseif not h:is_closing() then
        h:close()
      end
    end
  else
    -- Linux: build a precomputed ignore set, then walk.
    opts._ignore_set = {}
    for _, n in ipairs(opts.ignore_dirs or {}) do
      opts._ignore_set[n] = true
    end
    walk(state, state.root, opts, trigger)
  end
end

--- Stop all watchers and the debounce timer. Sets a guard flag so any in-flight
--- async walk callback closes its handle instead of re-registering it.
---@param state table
function M.stop(state)
  state.watch_stopped = true
  if state.watchers then
    if state.watchers.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, state.watchers.augroup)
    end
    for _, h in ipairs(state.watchers.events or {}) do
      if h and not h:is_closing() then
        h:stop()
        h:close()
      end
    end
    state.watchers = {}
  end
  if state.debounce_timer then
    state.debounce_timer:stop()
    if not state.debounce_timer:is_closing() then
      state.debounce_timer:close()
    end
    state.debounce_timer = nil
  end
  state.pending_changes = nil
  state.pending_unknown = nil
end

return M
