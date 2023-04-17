local log = require("plenary.log")
local Mock = require("diffview.mock").Mock

local fmt = string.format

---@class Logger
---@field plugin string
---@field trace fun(...: any)
---@field debug fun(...: any)
---@field info fun(...: any)
---@field warn fun(...: any)
---@field error fun(...: any)
---@field fatal fun(...: any)
---@field s_trace fun(...: any)
---@field s_debug fun(...: any)
---@field s_info fun(...: any)
---@field s_warn fun(...: any)
---@field s_error fun(...: any)
---@field s_fatal fun(...: any)
local logger = log.new({
  plugin = "diffview",
  highlights = false,
  use_console = false,
  level = DiffviewGlobal.debug_level > 0 and "debug" or "info",
})

logger.mock = Mock()

logger.outfile = string.format(
  "%s/%s.log", vim.api.nvim_call_function("stdpath", { "cache" }),
  logger.plugin
)

---@return string
function logger.dstring(object)
  local tp = type(object)

  if tp == "thread"
    or tp == "function"
    or tp == "userdata"
  then
    return fmt("<%s %p>", tp, object)
  elseif tp == "table" then
    local mt = getmetatable(object)

    if mt and mt.__tostring then
      return tostring(object)
    elseif vim.tbl_islist(object) then
      if #object == 0 then return "[]" end
      local s = ""

      for i = 1, table.maxn(object) do
        if i > 1 then s = s .. ", " end
        s = s .. logger.dstring(object[i])
      end

      return "[ " .. s .. " ]"
    end

    return vim.inspect(object)
  end

  return tostring(object)
end

local function dvalues(...)
  local args = { ... }
  local ret = {}

  for i = 1, select("#", ...) do
    ret[i] = logger.dstring(args[i])
  end

  return ret
end

-- Add scheduled variants of the different log methods.
for _, kind in ipairs({ "trace", "debug", "info", "warn", "error", "fatal" }) do
  local orig_fn = logger[kind]
  logger[kind] = function(...)
    orig_fn(unpack(dvalues(...)))
  end
  logger["s_" .. kind] = vim.schedule_wrap(function(...)
    logger[kind](unpack(dvalues(...)))
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

  return logger.mock
end

---@class LogJobSpec
---@field func function|string
---@field context string
---@field no_stdout boolean
---@field no_stderr boolean
---@field debug_level integer

---@param job diffview.Job
---@param opt? LogJobSpec
function logger.log_job(job, opt)
  opt = opt or {}

  if opt.debug_level and DiffviewGlobal.debug_level < opt.debug_level then
    return
  end

  local stdout, stderr = job.stdout, job.stderr
  local args = vim.tbl_map(function(arg)
    -- Simple shell escape. NOTE: not valid for windows shell.
    return ("'%s'"):format(arg:gsub("'", [['"'"']]))
  end, job.args) --[[@as vector ]]

  local log_func = logger.s_debug
  local context = opt.context and ("[%s] "):format(opt.context) or ""

  if type(opt.func) == "string" then
    log_func = logger[opt.func]
  elseif type(opt.func) == "function" then
    ---@diagnostic disable-next-line: cast-local-type
    log_func = opt.func
  end

  log_func(("%s[job-info] Exit code: %s"):format(context, job.code))
  log_func(("%s     [cmd] %s %s"):format(context, job.command, table.concat(args, " ")))

  if job.cwd then
    log_func(("%s     [cwd] %s"):format(context, job.cwd))
  end
  if not opt.no_stdout and stdout[1] then
    log_func(context .. "  [stdout] " .. table.concat(stdout, "\n"))
  end
  if not opt.no_stderr and stderr[1] then
    log_func(context .. "  [stderr] " .. table.concat(stderr, "\n"))
  end
end

return logger
