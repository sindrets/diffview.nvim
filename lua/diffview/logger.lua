local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Mock = lazy.access("diffview.mock", "Mock") ---@type Mock|LazyModule
local Semaphore = lazy.access("diffview.control", "Semaphore") ---@type Semaphore|LazyModule
local loop = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await, pawait = async.await, async.pawait
local fmt = string.format
local pl = lazy.access(utils, "path") ---@type PathLib
local uv = vim.loop

local M = {}

---@class Logger.TimeOfDay
---@field hours integer
---@field mins integer
---@field secs integer
---@field micros integer
---@field tz string
---@field timestamp integer

---Get high resolution time of day
---@return Logger.TimeOfDay
local function time_of_day()
  local secs, micros = uv.gettimeofday()
  local tzs = os.date("%z") --[[@as string ]]

  local sign = tzs:match("[+-]") == "-" and -1 or 1
  local tz_h, tz_m = tzs:match("[+-]?(%d%d)(%d%d)")
  tz_h = tz_h * sign
  tz_m = tz_m * sign

  local ret = {}
  ret.hours = math.floor(((secs / (60 * 60)) % 24) + tz_h)
  ret.mins = math.floor(((secs / 60) % 60) + tz_m)
  ret.secs = (secs % 60)
  ret.micros = micros
  ret.tz = tzs
  ret.timestamp = secs

  return ret
end

---@alias Logger.LogFunc fun(self: Logger, ...)
---@alias Logger.FmtLogFunc fun(self: Logger, formatstring: string, ...)
---@alias Logger.LazyLogFunc fun(self: Logger, work: (fun(): ...))

---@class Logger : diffview.Object
---@operator call : Logger
---@field private outfile_status Logger.OutfileStatus
---@field private level integer # Max level. Messages of higher level will be ignored. NOTE: Higher level -> lower severity.
---@field private msg_buffer string[]
---@field private msg_sem Semaphore
---@field private batch_interval integer # Minimum time (ms) between each time batched messages are written to the output file.
---@field private batch_handle? Closeable
---@field plugin string
---@field outfile string
---@field trace Logger.LogFunc
---@field debug Logger.LogFunc
---@field info Logger.LogFunc
---@field warn Logger.LogFunc
---@field error Logger.LogFunc
---@field fatal Logger.LogFunc
---@field fmt_trace Logger.FmtLogFunc
---@field fmt_debug Logger.FmtLogFunc
---@field fmt_info Logger.FmtLogFunc
---@field fmt_warn Logger.FmtLogFunc
---@field fmt_error Logger.FmtLogFunc
---@field fmt_fatal Logger.FmtLogFunc
---@field lazy_trace Logger.LazyLogFunc
---@field lazy_debug Logger.LazyLogFunc
---@field lazy_info Logger.LazyLogFunc
---@field lazy_warn Logger.LazyLogFunc
---@field lazy_error Logger.LazyLogFunc
---@field lazy_fatal Logger.LazyLogFunc
local Logger = oop.create_class("Logger")

---@enum Logger.OutfileStatus
Logger.OutfileStatus = {
  UNKNOWN = 1,
  READY = 2,
  ERROR = 3,
}
vim.tbl_add_reverse_lookup(Logger.OutfileStatus)

---@enum Logger.LogLevels
Logger.LogLevels = {
  fatal = 0,
  error = 1,
  warn = 2,
  info = 3,
  debug = 4,
  trace = 5,
}
vim.tbl_add_reverse_lookup(Logger.LogLevels)

Logger.mock = Mock()

function Logger:init(opt)
  opt = opt or {}
  self.plugin = opt.plugin or "diffview"
  self.outfile = opt.outfile or fmt("%s/%s.log", vim.fn.stdpath("cache"), self.plugin)
  self.outfile_status = Logger.OutfileStatus.UNKNOWN
  self.level = DiffviewGlobal.debug_level > 0 and Logger.LogLevels.debug or Logger.LogLevels.info
  self.msg_buffer = {}
  self.msg_sem = Semaphore(1)
  self.batch_interval = opt.batch_interval or 3000
end

---@param num number
---@param precision number
---@return number
local function to_precision(num, precision)
  if num % 1 == 0 then return num end
  local pow = math.pow(10, precision)
  return math.floor(num * pow) / pow
end

---@param object any
---@return string
function Logger.dstring(object)
  local tp = type(object)

  if tp == "thread"
    or tp == "function"
    or tp == "userdata"
  then
    return fmt("<%s %p>", tp, object)
  elseif tp == "number" then
    return tostring(to_precision(object, 3))
  elseif tp == "table" then
    local mt = getmetatable(object)

    if mt and mt.__tostring then
      return tostring(object)
    elseif vim.tbl_islist(object) then
      if #object == 0 then return "[]" end
      local s = ""

      for i = 1, table.maxn(object) do
        if i > 1 then s = s .. ", " end
        s = s .. Logger.dstring(object[i])
      end

      return "[ " .. s .. " ]"
    end

    return vim.inspect(object)
  end

  return tostring(object)
end

---@param min_level integer
---@return Logger
function Logger:lvl(min_level)
  if DiffviewGlobal.debug_level >= min_level then
    return self
  end

  ---@diagnostic disable-next-line: return-type-mismatch
  return Logger.mock
end

local function dvalues(...)
  local args = { ... }
  local ret = {}

  for i = 1, select("#", ...) do
    ret[i] = Logger.dstring(args[i])
  end

  return ret
end

---@private
---@param level_name string
---@param debuginfo? debuginfo
---@param ... any
function Logger:_log(level_name, debuginfo, ...)
  local args = dvalues(...)
  local info = debuginfo or debug.getinfo(3, "Sl")
  local lineinfo = info.short_src .. ":" .. info.currentline
  local tod = time_of_day()
  local date = fmt(
    "%s %02d:%02d:%02d.%03d %s",
    os.date("%F"),
    tod.hours,
    tod.mins,
    tod.secs,
    math.floor(tod.micros / 1000),
    tod.tz
  )

  self:queue_msg(
    fmt(
      "[%-6s%s] %s: %s\n",
      level_name:upper(),
      date,
      lineinfo,
      table.concat(args, " ")
    )
  )
end

---@diagnostic disable: invisible

---@private
---@param self Logger
---@param msg string
Logger.queue_msg = async.void(function(self, msg)
  if self.outfile_status == Logger.OutfileStatus.ERROR then
    -- We already failed to prepare the log file
    return
  elseif self.outfile_status == Logger.OutfileStatus.UNKNOWN then
    local ok, err = pawait(pl.touch, pl, self.outfile, { parents = true })

    if not ok then
      error("Failed to prepare log file! Details:\n" .. err)
    end

    self.outfile_status = Logger.OutfileStatus.READY
  end

  local permit = await(self.msg_sem:acquire()) --[[@as Permit ]]
  table.insert(self.msg_buffer, msg)
  permit:forget()

  if self.batch_handle then return end

  self.batch_handle = loop.set_timeout(
    async.void(function()
      ---@diagnostic disable-next-line: redefined-local
      local permit

      if next(self.msg_buffer) then
        permit = await(self.msg_sem:acquire()) --[[@as Permit ]]

        local fd, err = uv.fs_open(self.outfile, "a", tonumber("0644", 8))
        assert(fd, err)
        uv.fs_write(fd, table.concat(self.msg_buffer))
        uv.fs_close(fd)

        self.msg_buffer = {}
      end

      self.batch_handle = nil
      if permit then permit:forget() end
    end),
    self.batch_interval
  )
end)

do
  -- Create methods
  for level, name in ipairs(Logger.LogLevels --[[@as string[] ]]) do
    ---@param self Logger
    Logger[name] = function(self, ...)
      if self.level < level then return end
      self:_log(name, nil, ...)
    end

    ---@param self Logger
    Logger["fmt_" .. name] = function(self, formatstring, ...)
      if self.level < level then return end
      self:_log(name, nil, fmt(formatstring, ...))
    end
  end
end

---@diagnostic enable: invisible

---@class Logger.log_job.Opt
---@field func function|string
---@field context string
---@field no_stdout boolean
---@field no_stderr boolean
---@field debug_level integer

---@param job diffview.Job
---@param opt? Logger.log_job.Opt
function Logger:log_job(job, opt)
  opt = opt or {}

  if opt.debug_level and DiffviewGlobal.debug_level < opt.debug_level then
    return
  end

  local args = vim.tbl_map(function(arg)
    -- Simple shell escape. NOTE: not valid for windows shell.
    return ("'%s'"):format(arg:gsub("'", [['"'"']]))
  end, job.args) --[[@as vector ]]

  local log_func = self.debug
  local context = opt.context and ("[%s] "):format(opt.context) or ""

  if type(opt.func) == "string" then
    log_func = self[opt.func]
  elseif type(opt.func) == "function" then
    ---@diagnostic disable-next-line: cast-local-type
    log_func = opt.func
  end

  log_func(self, ("%s[job-info] Exit code: %s"):format(context, job.code))
  log_func(self, ("%s     [cmd] %s %s"):format(context, job.command, table.concat(args, " ")))

  if job.cwd then
    log_func(self, ("%s     [cwd] %s"):format(context, job.cwd))
  end
  if not opt.no_stdout and job.stdout[1] then
    log_func(self, context .. "  [stdout] " .. table.concat(job.stdout, "\n"))
  end
  if not opt.no_stderr and job.stderr[1] then
    log_func(self, context .. "  [stderr] " .. table.concat(job.stderr, "\n"))
  end
end

M.Logger = Logger

return M
