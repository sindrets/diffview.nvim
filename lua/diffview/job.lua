---@diagnostic disable: invisible
local oop = require("diffview.oop")
local async = require("diffview.async")
local lazy = require("diffview.lazy")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger
local uv = vim.loop

local M = {}

---@alias diffview.Job.OnOutCallback fun(err?: string, line: string, j: diffview.Job)
---@alias diffview.Job.OnExitCallback fun(j: diffview.Job, success: boolean, err?: string)
---@alias diffview.Job.OnRetryCallback fun(j: diffview.Job)
---@alias diffview.Job.FailCond fun(j: diffview.Job): boolean, string

---@alias StdioKind "in"|"out"|"err"

---@class diffview.Job : Waitable
---@operator call: diffview.Job
---@field command string
---@field args string[]
---@field cwd string
---@field retry integer
---@field check_status diffview.Job.FailCond
---@field log_opt Logger.log_job.Opt
---@field writer string|string[]
---@field env string[]
---@field stdout string[]
---@field stderr string[]
---@field handle uv_process_t
---@field pid integer
---@field code integer
---@field signal integer
---@field p_out uv_pipe_t
---@field p_err uv_pipe_t
---@field p_in? uv_pipe_t
---@field buffered_std boolean
---@field on_stdout_listeners diffview.Job.OnOutCallback[]
---@field on_stderr_listeners diffview.Job.OnOutCallback[]
---@field on_exit_listeners diffview.Job.OnExitCallback[]
---@field on_retry_listeners diffview.Job.OnRetryCallback[]
---@field _started boolean
---@field _done boolean
---@field _retry_count integer
local Job = oop.create_class("Job", async.Waitable)

local function prepare_env(env)
  local ret = {}

  for k, v in pairs(env) do
    table.insert(ret, k .. "=" .. v)
  end

  return ret
end

---Predefined fail conditions.
Job.FAIL_COND = {
  ---Fail on all non-zero exit codes.
  ---@param j diffview.Job
  non_zero = function(j)
    return j.code == 0, fmt("Job exited with a non-zero exit code: %d", j.code)
  end,
  ---Fail if there's no data in stdout.
  ---@param j diffview.Job
  on_empty = function(j)
    local msg = fmt("Job expected output, but returned nothing! Code: %d", j.code)
    local n = #j.stdout
    if n == 0 or (n == 1 and j.stdout[1] == "") then return false, msg end
    return true
  end,
}

function Job:init(opt)
  self.command = opt.command
  self.args = opt.args
  self.cwd = opt.cwd
  self.env = opt.env and prepare_env(opt.env) or prepare_env(uv.os_environ())
  self.retry = opt.retry or 0
  self.writer = opt.writer
  self.buffered_std = utils.sate(opt.buffered_std, true)
  self.on_stdout_listeners = {}
  self.on_stderr_listeners = {}
  self.on_exit_listeners = {}
  self.on_retry_listeners = {}
  self._started = false
  self._done = false
  self._retry_count = 0

  self.log_opt = vim.tbl_extend("keep", opt.log_opt or {}, {
    func = "debug",
    no_stdout = true,
    debuginfo = debug.getinfo(3, "Sl"),
  })

  if opt.fail_cond then
    if type(opt.fail_cond) == "string" then
      self.check_status = Job.FAIL_COND[opt.fail_cond]
      assert(self.check_status, fmt("Unknown fail condition: '%s'", opt.fail_cond))
    elseif type(opt.fail_cond) == "function" then
      self.check_status = opt.fail_cond
    else
      error("Invalid fail condition: " .. vim.inspect(opt.fail_cond))
    end
  else
    self.check_status = Job.FAIL_COND.non_zero
  end

  if opt.on_stdout then self:on_stdout(opt.on_stdout) end
  if opt.on_stderr then self:on_stderr(opt.on_stderr) end
  if opt.on_exit then self:on_exit(opt.on_exit) end
  if opt.on_retry then self:on_retry(opt.on_retry) end
end

---@param ... uv_handle_t
local function try_close(...)
  local args = { ... }

  for i = 1, select("#", ...) do
    local handle = args[i]
    if handle and not handle:is_closing() then
      handle:close()
    end
  end
end

---@param chunks string[]
---@return string[] lines
local function process_chunks(chunks)
  local data = table.concat(chunks)

  if data == "" then
    return {}
  end

  local has_eof = data:sub(-1) == "\n"
  local ret = vim.split(data, "\r?\n")
  if has_eof then ret[#ret] = nil end

  return ret
end

---@private
---@param pipe uv_pipe_t
---@param out string[]
---@param err? string
---@param data? string
function Job:buffered_reader(pipe, out, err, data)
  if err then
    logger:error("[Job:buffered_reader()] " .. err)
  end

  if data then
    out[#out + 1] = data
  else
    try_close(pipe)
  end
end

---@private
---@param pipe uv_pipe_t
---@param out string[]
---@param line_listeners? diffview.Job.OnOutCallback[]
function Job:line_reader(pipe, out, line_listeners)
  local line_buffer

  ---@param err? string
  ---@param data? string
  return function (err, data)
    if err then
      logger:error("[Job:line_reader()] " .. err)
    end

    if data then
      local has_eol = data:sub(-1) == "\n"
      local lines = vim.split(data, "\r?\n")

      lines[1] = (line_buffer or "") .. lines[1]
      line_buffer = nil

      for i, line in ipairs(lines) do
        if not has_eol and i == #lines then
          line_buffer = line
        else
          out[#out+1] = line

          if line_listeners then
            for _, listener in ipairs(line_listeners) do
              listener(nil, line, self)
            end
          end
        end
      end
    else
      if line_buffer then
        out[#out+1] = line_buffer

        if line_listeners then
          for _, listener in ipairs(line_listeners) do
            listener(nil, line_buffer, self)
          end
        end
      end

      try_close(pipe)
    end
  end
end

---@private
---@param pipe uv_pipe_t
---@param out string[]
---@param kind StdioKind
function Job:handle_reader(pipe, out, kind)
  if self.buffered_std then
    pipe:read_start(utils.bind(self.buffered_reader, self, pipe, out))
  else
    local listeners = ({
      out = self.on_stdout_listeners,
      err = self.on_stderr_listeners,
    })[kind] or {}
    pipe:read_start(self:line_reader(pipe, out, listeners))
  end
end

---@private
---@param pipe uv_pipe_t
---@param data string|string[]
function Job:handle_writer(pipe, data)
  if type(data) == "string" then
    if data:sub(-1) ~= "\n" then data = data .. "\n" end
    pipe:write(data, function(err)
      if err then
        logger:error("[Job:handle_writer()] " .. err)
      end

      try_close(pipe)
    end)

  else
    ---@cast data string[]
    local c = #data

    for i, s in ipairs(data) do
      if i ~= c then
        pipe:write(s .. "\n")
      else
        pipe:write(s .. "\n", function(err)
          if err then
            logger:error("[Job:handle_writer()] " .. err)
          end

          try_close(pipe)
        end)
      end
    end
  end
end

---@private
function Job:reset()
  try_close(self.handle, self.p_out, self.p_err, self.p_in)

  self.handle = nil
  self.p_out = nil
  self.p_err = nil
  self.p_in = nil

  self.stdout = {}
  self.stderr = {}
  self.pid = nil
  self.code = nil
  self.signal = nil
  self._started = false
  self._done = false
end

---@param self diffview.Job
---@param callback fun(success: boolean, err?: string)
Job.start = async.wrap(function(self, callback)
  self:reset()

  self.p_out = uv.new_pipe(false)
  self.p_err = uv.new_pipe(false)

  assert(self.p_out and self.p_err, "Failed to create pipes!")

  if self.writer then
    self.p_in = uv.new_pipe(false)
    assert(self.p_in, "Failed to create pipes!")
  end

  self._started = true

  local handle, pid

  handle, pid = uv.spawn(self.command, {
    args = self.args,
    stdio = { self.p_in, self.p_out, self.p_err },
    cwd = self.cwd,
    env = self.env,
    hide = true,
  },
  function(code, signal)
    ---@cast handle -?
    handle:close()
    self.p_out:read_stop()
    self.p_err:read_stop()

    if not self.code then self.code = code end
    if not self.signal then self.signal = signal end

    try_close(self.p_out, self.p_err, self.p_in)

    if self.buffered_std then
      self.stdout = process_chunks(self.stdout)
      self.stderr = process_chunks(self.stderr)
    end

    ---@type boolean, string?
    local ok, err = self:is_success()
    local log = not self.log_opt.silent and logger or logger.mock --[[@as Logger ]]

    if not ok then
      log:error(err)
      log:log_job(self, { func = "error", no_stdout = true, debuginfo = self.log_opt.debuginfo })

      if self.retry > 0 then
        if self._retry_count < self.retry then
          self:do_retry(callback)
          return
        else
          log:error("All retries failed!")
        end
      end
    else
      if self._retry_count > 0 then
        log:info("Retry was successful!")
      end

      log:log_job(self, self.log_opt)
    end

    self._retry_count = 0
    self._done = true

    for _, listener in ipairs(self.on_exit_listeners) do
      listener(self, ok, err)
    end

    callback(ok, err)
  end)

  if not handle then
    try_close(self.p_out, self.p_err, self.p_in)
    error("Failed to spawn job!")
  end

  self.handle = handle
  self.pid = pid

  self:handle_reader(self.p_out, self.stdout, "out")
  self:handle_reader(self.p_err, self.stderr, "err")

  if self.p_in then
    self:handle_writer(self.p_in, self.writer)
  end
end)

---@private
---@param self diffview.Job
---@param callback function
Job.do_retry = async.void(function(self, callback)
  self._retry_count = self._retry_count + 1

  if not self.log_opt.silent then
    logger:fmt_warn("(%d/%d) Retrying job...", self._retry_count, self.retry)
  end

  await(async.timeout(1))

  for _, listener in ipairs(self.on_retry_listeners) do
    listener(self)
  end

  self:start(callback)
end)

---@param self diffview.Job
---@param timeout? integer # Max duration (ms) (default: 30_000)
---@return boolean success
---@return string? err
function Job:sync(timeout)
  if not self:is_started() then
    self:start()
  end

  await(async.scheduler())

  if self:is_done() then
    return self:is_success()
  end

  local ok, status = vim.wait(timeout or (30 * 1000), function()
    return self:is_done()
  end, 1)

  await(async.scheduler())

  if not ok then
    if status == -1 then
      error("Synchronous job timed out!")
    elseif status == -2 then
      error("Synchronous job got interrupted!")
    end

    return false, "Unexpected state"
  end

  return self:is_success()
end

---@param code integer
---@param signal? integer|uv.aliases.signals # (default: "sigterm")
---@return 0? success
---@return string? err_name
---@return string? err_msg
function Job:kill(code, signal)
  if not self.handle then return 0 end

  if not self.handle:is_closing() then
    self.code = code
    self.signal = signal
    return self.handle:kill(signal or "sigterm")
  end

  return 0
end

---@override
---@param self diffview.Job
---@param callback fun(success: boolean, err?: string)
Job.await = async.sync_wrap(function(self, callback)
  if self:is_done() then
    callback(self:is_success())
  elseif self:is_running() then
    self:on_exit(function(_, ...) callback(...) end)
  else
    callback(await(self:start()))
  end
end)

---@param jobs diffview.Job[]
function Job.start_all(jobs)
  for _, job in ipairs(jobs) do
    job:start()
  end
end

---@param jobs diffview.Job[]
---@param callback fun(success: boolean, errors?: string[])
Job.join = async.wrap(function(jobs, callback)
  -- Start by ensuring all jobs are running
  for _, job in ipairs(jobs) do
    if not job:is_started() then
      job:start()
    end
  end

  local success, errors = true, {}

  for _, job in ipairs(jobs) do
    local ok, err = await(job)
    if not ok then
      success = false
      errors[#errors + 1] = err
    end
  end

  callback(success, not success and errors or nil)
end)

---@param jobs diffview.Job[]
Job.chain = async.void(function(jobs)
  for _, job in ipairs(jobs) do
    await(job)
  end
end)

---Subscribe to stdout data. Only used if `buffered_std=false`.
---@param callback diffview.Job.OnOutCallback
function Job:on_stdout(callback)
  table.insert(self.on_stdout_listeners, callback)

  if not self:is_started() then
    self.buffered_std = false
  end
end

---Subscribe to stderr data. Only used if `buffered_std=false`.
---@param callback diffview.Job.OnOutCallback
function Job:on_stderr(callback)
  table.insert(self.on_stderr_listeners, callback)

  if not self:is_running() then
    self.buffered_std = false
  end
end

---@param callback diffview.Job.OnExitCallback
function Job:on_exit(callback)
  table.insert(self.on_exit_listeners, callback)
end

---@param callback diffview.Job.OnRetryCallback
function Job:on_retry(callback)
  table.insert(self.on_retry_listeners, callback)
end

---@return boolean success
---@return string? err
function Job:is_success()
  local ok, err = self:check_status()
  if not ok then return false, err end
  return true
end

function Job:is_done()
  return self._done
end

function Job:is_started()
  return self._started
end

function Job:is_running()
  return self:is_started() and not self:is_done()
end

M.Job = Job

return M
