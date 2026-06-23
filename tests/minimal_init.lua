-- minimal_init.lua — runtimepath bootstrap for the test suite.
-- Adds this plugin and plenary.nvim to the runtimepath. plenary is a DEV-ONLY
-- dependency: we look in common install locations, and clone it into
-- tests/.deps as a last resort so the suite is portable / CI-runnable.
local uv = vim.uv or vim.loop

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h")
end

local TESTS = script_dir()
local ROOT = vim.fn.fnamemodify(TESTS, ":h")

vim.opt.runtimepath:prepend(ROOT)
-- Make `require("tests.helpers")` resolve to tests/helpers/init.lua.
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local function exists(p)
  return p and uv.fs_stat(p) ~= nil
end

-- Candidate plenary locations (lazy/packer on Windows + Unix, plus our cache).
local data = vim.fn.stdpath("data")
local candidates = {
  data .. "/lazy/plenary.nvim",
  data .. "/site/pack/packer/start/plenary.nvim",
  data .. "/site/pack/vendor/start/plenary.nvim",
  TESTS .. "/.deps/plenary.nvim",
}

local plenary
for _, c in ipairs(candidates) do
  if exists(c .. "/lua/plenary/busted.lua") then
    plenary = c
    break
  end
end

if not plenary then
  local dest = TESTS .. "/.deps/plenary.nvim"
  vim.fn.mkdir(TESTS .. "/.deps", "p")
  print("plenary.nvim not found; cloning to " .. dest)
  vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    dest,
  })
  plenary = dest
end

vim.opt.runtimepath:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")
-- Load our plugin's commands/autocmds too.
vim.cmd("runtime plugin/liz-live-server.lua")
