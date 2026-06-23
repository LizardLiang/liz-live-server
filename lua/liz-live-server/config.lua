-- config.lua — default options and setup() deep-merge.
local M = {}

--- Default configuration (tech-spec §4 "Config defaults").
M.defaults = {
  host = "127.0.0.1", -- localhost-only (FR-009); never 0.0.0.0
  port = 5500, -- FR-006 default; auto-increments if busy
  max_port_tries = 50, -- give up after N busy ports -> error notify
  open = true, -- auto-open browser; opt-out (FR-005/FR-020)
  root = nil, -- nil -> vim.fn.getcwd()
  debounce_ms = 50, -- FR-011 coalesce window
  ping_ms = 30000, -- SSE keep-alive interval
  ignore_dirs = { ".git", "node_modules" }, -- fs_event Linux-walk pruning
}

-- Active config; starts as a copy of defaults, replaced by setup().
M.options = vim.deepcopy(M.defaults)

--- Merge user opts over defaults (deep).
---@param opts table|nil
---@return table merged options
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
