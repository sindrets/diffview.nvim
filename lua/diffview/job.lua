local oop = require("diffview.oop")
local async = require("plenary.async")
local lazy = require("diffview.lazy")

local logger = lazy.require("diffview.logger") ---@module "diffview.logger"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local uv = vim.loop

local M = {}

---@alias diffview.Job.OnOutCallback fun(err?: string, line: string, j: diffview.Job)
---@alias diffview.Job.OnExitCallback fun(j: diffview.Job, code: integer, signal: integer)

---@class diffview.Job
---@operator call: diffview.Job
---@field command string
---@field args string[]
---@field cwd string
---@field writer string|string[]
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
---@field _started boolean
local Job = oop.create_class("Job")

function Job:init(opt)
  self.command = opt.command
  self.args = opt.args
  self.cwd = opt.cwd
  self.writer = opt.writer
  self.env = opt.env or uv.os_environ()
  self.buffered_std = utils.sate(opt.buffered_std, true)
  self.on_stdout_listeners = {}
  self.on_stderr_listeners = {}
  self.on_exit_listeners = {}
  self._started = false

  if opt.on_stdout then self:on_stdout(opt.on_stdout) end
  if opt.on_stderr then self:on_stderr(opt.on_stderr) end
  if opt.on_exit then self:on_exit(opt.on_exit) end
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

---@private
---@param pipe uv_pipe_t
---@param out string[]
---@param err? string
---@param data? string
function Job:buffered_reader(pipe, out, err, data)
  if err then
    logger.error("[Job:buffered_reader()] " .. err)
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
---@param err? string
---@param data? string
function Job:line_reader(pipe, out, err, data)
  local line_buffer

  if err then
    logger.error("[Job:line_reader()] " .. err)
  end

  if data then
    local has_eol = data[#data] == "\n"
    local lines = vim.split(data, "\r?\n")

    if #lines > 0 then
      lines[1] = (line_buffer or "") .. lines[1]
    end

    line_buffer = nil

    for i, line in ipairs(lines) do
      if not has_eol and i == #lines then
        line_buffer = line
      else
        out[#out+1] = line

        for _, listener in ipairs(self.on_stdout_listeners) do
          listener(nil, line, self)
        end
      end
    end
  else
    if line_buffer then
      out[#out+1] = line_buffer

      for _, listener in ipairs(self.on_stdout_listeners) do
        listener(nil, line_buffer, self)
      end
    end

    try_close(pipe)
  end
end

---@private
---@param pipe uv_pipe_t
---@param out string[]
function Job:handle_reader(pipe, out)
  if self.buffered_std then
    pipe:read_start(utils.bind(self.buffered_reader, self, pipe, out))
  else
    pipe:read_start(utils.bind(self.line_reader, self, pipe, out))
  end
end

---@private
---@param pipe uv_pipe_t
---@param data string|string[]
function Job:handle_writer(pipe, data)
  if type(data) == "string" then
    pipe:write(data, function(err)
      -- TODO: Handle error
      try_close(pipe)
    end)

  elseif vim.tbl_islist(data) then
    ---@cast data string[]
    local c = #data

    for i, s in ipairs(data) do
      if i ~= c then
        pipe:write(s .. "\n")
      else
        pipe:write(s .. "\n", function(err)
          -- TODO: Handle error
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
end

---@param self diffview.Job
function Job:start()
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
      for _, key in ipairs({ "stdout", "stderr" }) do
        local chunks = self[key]

        local data = table.concat(chunks)

        if data == "" then
          self[key] = {}
        else
          local has_eof = string.sub(data, #data) == "\n"
          self[key] = vim.split(data, "\r?\n")
          if has_eof then self[key][#self[key]] = nil end
        end
      end
    end

    for _, listener in ipairs(self.on_exit_listeners) do
      listener(self, code, signal)
    end
  end)

  if not handle then
    try_close(self.p_out, self.p_err, self.p_in)
    error("Failed to spawn job!")
  end

  self.handle = handle
  self.pid = pid

  self:handle_reader(self.p_out, self.stdout)
  self:handle_reader(self.p_err, self.stderr)

  if self.p_in then
    self:handle_writer(self.p_in, self.writer)
  end
end

---@param duration? integer # Max duration (ms)
---@return string[] stdout
---@return integer code
---@return string[] stderr
function Job:sync(duration)
  if self:is_done() then
    return self.stdout, self.code, self.stderr
  end

  if not self._started then self:start() end

  if vim.in_fast_event() then
    async.util.scheduler()
  end

  local ok, status = vim.wait(duration or 5000, function()
    return self:is_done()
  end, 10)

  if not ok then
    if status == -1 then
      error("Synchronous job timed out!")
    elseif status == -2 then
      error("Synchronous job got interrupted!")
    end

    return {}, 1, {}
  end

  return self.stdout, self.code, self.stderr
end

---@param code integer
---@param signal integer|uv.aliases.signals
---@return 0? success
---@return string? err_name
---@return string? err_msg
function Job:kill(code, signal)
  if not self.handle then return 0 end

  if not self.handle:is_closing() then
    self.code = code
    self.signal = signal
    return self.handle:kill(signal or "sigkill")
  end

  return 0
end

---@param jobs diffview.Job[]
---@param callback fun()
Job.join = async.wrap(function(jobs, callback)
  -- Start by ensuring all jobs are running
  for _, job in ipairs(jobs) do
    if not job:is_done() and not job._started then
      job:start()
    end
  end

  local done_count = 0

  local function exit_cb()
    done_count = done_count + 1
    if done_count == #jobs then
      callback()
    end
  end

  for _, job in ipairs(jobs) do
    if job:is_done() then
      exit_cb()
    else
      job:on_exit(exit_cb)
    end
  end
end, 2)

---@param jobs diffview.Job[]
---@param callback fun()
Job.chain = async.wrap(function(jobs, callback)
  local idx = 0

  local function resume()
    idx = idx + 1
    local job = jobs[idx]

    if not job then
      -- We have reached the end of the queue
      callback()
    elseif job:is_done() then
      -- Job is already done: continue
      resume()
    else
      -- Wait for the job to exit
      job:on_exit(resume)

      if not job._started then
        job:start()
      end
    end
  end

  resume()
end, 2)

---Subscribe to stdout data. Only used if `buffered_std=false`.
---@param callback diffview.Job.OnOutCallback
function Job:on_stdout(callback)
  table.insert(self.on_stdout_listeners, callback)

  if not self._started then
    self.buffered_std = false
  end
end

---Subscribe to stderr data. Only used if `buffered_std=false`.
---@param callback diffview.Job.OnOutCallback
function Job:on_stderr(callback)
  table.insert(self.on_stderr_listeners, callback)

  if not self._started then
    self.buffered_std = false
  end
end

---@param callback diffview.Job.OnExitCallback
function Job:on_exit(callback)
  table.insert(self.on_exit_listeners, callback)
end

function Job:is_done()
  return not not (self.handle and self.handle:is_closing())
end

M.Job = Job

return M
