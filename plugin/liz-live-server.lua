-- plugin/liz-live-server.lua — user commands + teardown autocmd.
-- Loaded once at startup; does no heavy work at require time (lazy-requires the
-- core module only when a command fires).
if vim.g.loaded_liz_live_server then
  return
end
vim.g.loaded_liz_live_server = true

local function liz()
  return require("liz-live-server")
end

vim.api.nvim_create_user_command("LiveServerStart", function()
  liz().start()
end, { desc = "Start the HTML live server" })

vim.api.nvim_create_user_command("LiveServerStop", function()
  liz().stop()
end, { desc = "Stop the HTML live server" })

vim.api.nvim_create_user_command("LiveServerToggle", function()
  liz().toggle()
end, { desc = "Toggle the HTML live server" })

-- Clean teardown so no listen socket / watcher / timer leaks on exit (FR-010).
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("LizLiveServerLifecycle", { clear = true }),
  callback = function()
    local ok, mod = pcall(require, "liz-live-server")
    if ok and mod.state and mod.state.running then
      mod.stop()
    end
  end,
})
