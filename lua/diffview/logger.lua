local utils = require("diffview.utils")
local log = require("plenary.log")
local Mock = require("diffview.mock").Mock

---@class Logger
---@field plugin string
---@field trace fun(obj: any)
---@field debug fun(obj: any)
---@field info fun(obj: any)
---@field warn fun(obj: any)
---@field error fun(obj: any)
---@field fatal fun(obj: any)
---@field s_trace fun(obj: any)
---@field s_debug fun(obj: any)
---@field s_info fun(obj: any)
---@field s_warn fun(obj: any)
---@field s_error fun(obj: any)
---@field s_fatal fun(obj: any)
local logger = log.new({
  plugin = "diffview",
  highlights = false,
  use_console = false,
  level = DiffviewGlobal.debug_level > 0 and "debug" or "info",
})

local mock_logger = Mock()

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

---Require a minimum debug level. Returns a mock object if requirement is not
---met.
---@param min_level integer
---@return Logger
function logger.lvl(min_level)
  if DiffviewGlobal.debug_level >= min_level then
    return logger
  end
  return mock_logger
end

---@param job Job
---@param log_func function
function logger.log_job(job, log_func)
  local stdout, stderr = job:result(), job:stderr_result()
  local args = vim.tbl_map(function(arg)
    -- Simple shell escape. NOTE: not valid for windows shell.
    return ("'%s'"):format(arg:gsub("'", [['"'"']]))
  end, job.args)

  if type(log_func) == "string" then
    log_func = logger[log_func]
  end

  log_func(("[job-info] Exit code: %s"):format(job.code))
  log_func(("[cmd] %s %s"):format(job.command, table.concat(args, " ")))

  if #stdout > 0 then
    log_func("[stdout] " .. table.concat(stdout, "\n"))
  end
  if #stderr > 0 then
    log_func("[stderr] " .. table.concat(stderr, "\n"))
  end
end

return logger
