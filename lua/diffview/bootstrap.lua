if DiffviewGlobal and DiffviewGlobal.bootstrap_done then
  return DiffviewGlobal.bootstrap_ok
end

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

-- Ensure dependencies
local ok = pcall(require, "plenary")
if not ok then
  err(
    "Dependency 'plenary.nvim' is not installed! "
    .. "See ':h diffview.changelog-93' for more information."
  )
  return false
end

_G.DiffviewGlobal = {
  ---Debug Levels:
  ---0:     NOTHING
  ---1:     NORMAL
  ---5:     LOADING
  ---10:    RENDERING
  debug_level = tonumber(os.getenv("DEBUG_DIFFVIEW")) or 0,
  ---@type EventEmitter
  emitter = require("diffview.events").EventEmitter(),
  bootstrap_done = true,
  bootstrap_ok = true,
}

DiffviewGlobal.emitter:on_any(function(event, args)
  local utils = require("diffview.utils")
  require("diffview.config").user_emitter:nore_emit(event, utils.tbl_unpack(args))
end)

return true
