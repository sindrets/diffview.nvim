local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Job = lazy.access("diffview.job", "Job") ---@type diffview.Job|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@alias MultiJob.OnExitCallback fun(mj: MultiJob, success: boolean, err?: string)
---@alias MultiJob.OnRetryCallback fun(mj: MultiJob, jobs: diffview.Job[])
---@alias MultiJob.FailCond fun(mj: MultiJob): boolean, diffview.Job[]?, string?

---@class MultiJob : Waitable
---@operator call : MultiJob
---@field jobs diffview.Job[]
---@field retry integer
---@field check_status MultiJob.FailCond
---@field on_exit_listeners MultiJob.OnExitCallback[]
---@field _started boolean
---@field _done boolean
local MultiJob = oop.create_class("MultiJob")

---Predefined fail conditions.
MultiJob.FAIL_COND = {
  ---Fail if any of the jobs termintated with a non-zero exit code.
  ---@param mj MultiJob
  non_zero = function(mj)
    local failed = {}

    for _, job in ipairs(mj.jobs) do
      if job.code ~= 0 then
        failed[#failed + 1] = job
      end
    end

    if next(failed) then
      return false, failed, "Job(s) exited with a non-zero exit code!"
    end

    return true
  end,
  ---Fail if any of the jobs had no data in stdout.
  ---@param mj MultiJob
  on_empty = function(mj)
    local failed = {}

    for _, job in ipairs(mj.jobs) do
      if #job.stdout == 1 and job.stdout[1] == ""
        or #job.stdout == 0
      then
        failed[#failed + 1] = job
      end
    end

    if next(failed) then
      return false, failed, "Job(s) expected output, but returned nothing!"
    end

    return true
  end,
}

function MultiJob:init(jobs, opt)
  self.jobs = jobs
  self.retry = opt.retry or 0
  self.on_exit_listeners = {}
  self.on_retry_listeners = {}
  self._started = false
  self._done = false

  self.log_opt = vim.tbl_extend("keep", opt.log_opt or {}, {
    func = "debug",
    no_stdout = true,
    debuginfo = debug.getinfo(3, "Sl"),
  })

  if opt.fail_cond then
    if type(opt.fail_cond) == "string" then
      self.check_status = MultiJob.FAIL_COND[opt.fail_cond]
      assert(self.check_status, fmt("Unknown fail condition: '%s'", opt.fail_cond))
    elseif type(opt.fail_cond) == "function" then
      self.check_status = opt.fail_cond
    else
      error("Invalid fail condition: " .. vim.inspect(opt.fail_cond))
    end
  else
    self.check_status = MultiJob.FAIL_COND.non_zero
  end

  if opt.on_exit then self:on_exit(opt.on_exit) end
  if opt.on_retry then self:on_retry(opt.on_retry) end
end

---@private
function MultiJob:reset()
  self._started = false
  self._done = false
end

---@param self MultiJob
MultiJob.start = async.wrap(function(self, callback)
  ---@diagnostic disable: invisible
  for _, job in ipairs(self.jobs) do
    if job:is_running() then
      error("A job is still running!")
    end
  end

  self:reset()

  self._started = true

  local jobs = self.jobs
  local retry_status

  for i = 1, self.retry + 1 do
    if i > 1 then
      for _, listener in ipairs(self.on_retry_listeners) do
        listener(self, jobs)
      end
    end

    Job.start_all(jobs)
    await(Job.join(jobs))

    local ok, err
    ok, jobs, err = self:check_status()

    if ok then break end
    ---@cast jobs -?

    if i == self.retry + 1 then
      retry_status = 1
    else
      retry_status = 0

      if not self.log_opt.silent then
        logger:error(err)

        for _, job in ipairs(jobs) do
          logger:log_job(job, { func = "error", no_stdout = true })
        end

        logger:fmt_error("(%d/%d) Retrying failed jobs...", i, self.retry)
      end

      await(async.timeout(1))
    end
  end

  if not self.log_opt.silent then
    if retry_status == 0 then
      logger:info("Retry was successful!")
    elseif retry_status == 1 then
      logger:error("All retries failed!")
    end
  end

  self._done = true
  local ok, err = self:is_success()

  for _, listener in ipairs(self.on_exit_listeners) do
    listener(self, ok, err)
  end

  callback(ok, err)
  ---@diagnostic enable: invisible
end)

---@override
---@param self MultiJob
---@param callback fun(success: boolean, err?: string)
MultiJob.await = async.sync_wrap(function(self, callback)
  if self:is_done() then
    callback(self:is_success())
  elseif self:is_running() then
    self:on_exit(function(_, ...) callback(...) end)
  else
    callback(await(self:start()))
  end
end)

---@return boolean success
---@return string? err
function MultiJob:is_success()
  local ok, _, err = self:check_status()
  if not ok then return false, err end
  return true
end

---@param callback MultiJob.OnExitCallback
function MultiJob:on_exit(callback)
  table.insert(self.on_exit_listeners, callback)
end

---@param callback MultiJob.OnRetryCallback
function MultiJob:on_retry(callback)
  table.insert(self.on_retry_listeners, callback)
end

function MultiJob:is_done()
  return self._done
end

function MultiJob:is_started()
  return self._started
end

function MultiJob:is_running()
  return self:is_started() and not self:is_done()
end

---@return string[]
function MultiJob:stdout()
  return utils.flatten(
    ---@param value diffview.Job
    vim.tbl_map(function(value)
      return value.stdout
    end, self.jobs)
  )
end

---@return string[]
function MultiJob:stderr()
  return utils.flatten(
    ---@param value diffview.Job
    vim.tbl_map(function(value)
      return value.stderr
    end, self.jobs)
  )
end

---@param code integer
---@param signal? integer|uv.aliases.signals # (default: "sigterm")
---@return 0|nil success
function MultiJob:kill(code, signal)
  ---@type 0?
  local ret = 0

  for _, job in ipairs(self.jobs) do
    if job:is_running() then
      local success = job:kill(code, signal)
      if not success then ret = nil end
    end
  end

  return ret
end

M.MultiJob = MultiJob

return M
