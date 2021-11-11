local utils = require("diffview.utils")
local log = require("plenary.log")

local logger = log.new({
  plugin = "diffview",
  highlights = false,
  use_console = false,
  level = DiffviewGlobal.debug_level > 0 and "debug" or "error",
})

logger.outfile = string.format(
  "%s/%s.log", vim.api.nvim_call_function("stdpath", { "cache" }),
  logger.plugin
)

-- Add scheduled variants of the different log methods.
for _, kind in ipairs({ "trace", "debug", "info", "warn", "error", "fatal" }) do
  logger["s_" .. kind] = vim.schedule_wrap(function (...)
    local args = vim.tbl_map(function(v)
      if type(v) == "table" and type(v.__tostring) == "function" then
        return tostring(v)
      end
      return v
    end, utils.tbl_pack(...))
    logger[kind](utils.tbl_unpack(args))
  end)
end

return logger
