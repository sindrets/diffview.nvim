local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Mock = lazy.access("diffview.mock", "Mock") ---@type Mock|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local uv = vim.loop
local await = async.await
local fmt = string.format
local pl = lazy.access(utils, "path") ---@type PathLib

---@alias Logger.LogFunc fun(self: Logger, ...)
---@alias Logger.FmtLogFunc fun(self: Logger, formatstring: string, ...)
---@alias Logger.LazyLogFunc fun(self: Logger, work: (fun(): ...))

---@class Logger : diffview.Object
---@operator call : Logger
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

---@enum Logger.LogLevels
Logger.log_levels = vim.tbl_add_reverse_lookup({
  fatal = 0,
  error = 1,
  warn = 2,
  info = 3,
  debug = 4,
  trace = 5,
})

Logger.mock = Mock()

function Logger:init(opt)
  opt = opt or {}
  self.plugin = opt.plugin or "diffview"
  self.outfile = opt.outfile or fmt("%s/%s.log", vim.fn.stdpath("cache"), self.plugin)
  self.level = DiffviewGlobal.debug_level > 0 and Logger.log_levels.debug or Logger.log_levels.info

  await(pl:touch(self.outfile, { parents = true }))
end

function Logger.dstring(object)
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
        s = s .. Logger.dstring(object[i])
      end

      return "[ " .. s .. " ]"
    end

    return vim.inspect(object)
  end

  return tostring(object)
end

function Logger.dvalues(...)
  local args = { ... }
  local ret = {}

  for i = 1, select("#", ...) do
    ret[i] = Logger.dstring(args[i])
  end

  return ret
end

---@param min_level integer
---@return Logger
function Logger:lvl(min_level)
  if DiffviewGlobal.debug_level >= min_level then
    return self
  end

  return Logger.mock
end

---@private
function Logger:_log(level_name, ...)
  local args = utils.tbl_pack(...)
  local info = debug.getinfo(3, "Sl")
  local lineinfo = info.short_src .. ":" .. info.currentline

  vim.schedule(function()
    local msg = table.concat(Logger.dvalues(utils.tbl_unpack(args)), " ")
    local fd, err = uv.fs_open(self.outfile, "a", tonumber("0644", 8))
    assert(fd, err)
    local str = fmt("[%-6s%s] %s: %s\n", level_name:upper(), os.date(), lineinfo, msg)
    uv.fs_write(fd, str)
    uv.fs_close(fd)
  end)
end

do
  -- Create methods
  for level, name in ipairs(Logger.log_levels) do
    ---@param self Logger
    Logger[name] = function(self, ...)
      if self.level < level then return end
      ---@diagnostic disable-next-line: invisible
      self:_log(name, ...)
    end

    ---@param self Logger
    Logger["fmt_" .. name] = function(self, formatstring, ...)
      if self.level < level then return end
      ---@diagnostic disable-next-line: invisible
      self:_log(name, fmt(formatstring, ...))
    end
  end
end

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

local logger = Logger()

return logger
