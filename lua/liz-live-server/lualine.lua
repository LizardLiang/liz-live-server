-- lualine.lua — named lualine component reflecting server state (FR-008/023).
-- Running:  " :<port>"  (optionally "(n)" clients when FR-030 is enabled)
-- Stopped:  ""          (component renders nothing)
-- Error:    "LiveServer: error"
local M = {}

-- Nerd-font lightning bolt; renders as a box on terminals without Nerd Fonts.
local ICON = ""

--- Render the component string from the current runtime state.
---@param opts table|nil { show_clients = boolean }
---@return string
local function render(opts)
  opts = opts or {}
  local state = require("liz-live-server").state
  if state.error then
    return "LiveServer: error"
  end
  if not state.running then
    return ""
  end
  local s = ICON .. " :" .. tostring(state.port)
  if opts.show_clients then
    local sse = require("liz-live-server.sse")
    s = s .. " (" .. tostring(sse.count(state)) .. ")"
  end
  return s
end

-- Callable: lualine accepts a function component, and `require(...)()` works.
return setmetatable(M, {
  __call = function(_, opts)
    return render(opts)
  end,
})
