if DiffviewGlobal and DiffviewGlobal.bootstrap_done then
  return DiffviewGlobal.bootstrap_ok
end

local lazy = require("diffview.lazy")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local Logger = lazy.access("diffview.logger", "Logger") ---@type Logger|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local diffview = lazy.require("diffview") ---@module "diffview"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local uv = vim.loop

local function err(msg)
  msg = msg:gsub("'", "''")
  vim.cmd("echohl Error")
  vim.cmd(string.format("echom '[diffview.nvim] %s'", msg))
  vim.cmd("echohl NONE")
end

_G.DiffviewGlobal = {
  bootstrap_done = true,
  bootstrap_ok = false,
}

if vim.fn.has("nvim-0.7") ~= 1 then
  err(
    "Minimum required version is Neovim 0.7.0! Cannot continue."
    .. " (See ':h diffview.changelog-137')"
  )
  return false
end

_G.DiffviewGlobal = {
  ---Debug Levels:
  ---0:     NOTHING
  ---1:     NORMAL
  ---5:     LOADING
  ---10:    RENDERING & ASYNC
  ---@diagnostic disable-next-line: missing-parameter
  debug_level = tonumber((uv.os_getenv("DEBUG_DIFFVIEW"))) or 0,
  state = {},
  bootstrap_done = true,
  bootstrap_ok = true,
}

DiffviewGlobal.logger = Logger()
DiffviewGlobal.emitter = EventEmitter()

DiffviewGlobal.emitter:on_any(function(e, args)
  diffview.nore_emit(e.id, utils.tbl_unpack(args))
  config.user_emitter:nore_emit(e.id, utils.tbl_unpack(args))
end)

return true
