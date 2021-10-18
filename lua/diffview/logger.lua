local utils = require("diffview.utils")
local Mock = require("diffview.mock").Mock

-- If plenary is not installed: mock the logger object
local ok, log = pcall(require, "plenary.log")
if not ok then
  log = Mock({
    new = function()
      return log
    end,
  })
end

local logger = log.new({
  plugin = "diffview",
  highlights = false,
  use_console = false,
  level = DiffviewGlobal.debug_level > 0 and "debug" or "error",
})

-- Add scheduled variants of the different log methods.
for _, kind in ipairs({ "trace", "debug", "info", "warn", "error", "fatal" }) do
  logger["s_" .. kind] = function(...)
    local args = utils.tbl_pack(...)
    vim.schedule(function()
      args = vim.tbl_map(function(v)
        if type(v) == "table" and type(v.__tostring) == "function" then
          return tostring(v)
        end
        return v
      end, args)
      logger[kind](utils.tbl_unpack(args))
    end)
  end
end

return logger
