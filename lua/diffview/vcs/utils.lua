local utils = require("diffview.utils")
local async = require("plenary.async")
local Job = require("plenary.job")
local Semaphore = require('diffview.control').Semaphore

local M = {}

---@enum JobStatus
local JobStatus = {
  SUCCESS = 1,
  PROGRESS = 2,
  ERROR = 3,
  KILLED = 4,
  FATAL = 5,
}

---@type Job[]
local sync_jobs = {}
---@type Semaphore
local job_queue_sem = Semaphore.new(1)

---@param job Job
local resume_sync_queue = async.void(function(job)
  local permit = job_queue_sem:acquire()
  local idx = utils.vec_indexof(sync_jobs, job)
  if idx > -1 then
    table.remove(sync_jobs, idx)
  end
  permit:forget()

  if sync_jobs[1] and not sync_jobs[1].handle then
    sync_jobs[1]:start()
  end
end)

---@param job Job
local queue_sync_job = async.void(function(job)
  job:add_on_exit_callback(function()
    resume_sync_queue(job)
  end)

  local permit = job_queue_sem:acquire()
  table.insert(sync_jobs, job)
  permit:forget()

  if #sync_jobs == 1 then
    job:start()
  end
end)

M.show = async.wrap(function(adapter, args, callback) 
  local job = Job:new({
    command = adapter:bin(),
    args = utils.vec_join(
      adapter:args(),
      "show",
      args
    ),
    cwd = adapter.context.toplevel,
    ---@type Job
    on_exit = async.void(function(j)
      local context = "git.utils.show()"
      utils.handle_job(j, {
        fail_on_empty = true,
        context = context,
        debug_opt = { no_stdout = true, context = context },
      })

      if j.code ~= 0 then
        callback(j:stderr_result() or {}, nil)
        return
      end

      local out_status

      if #j:result() == 0 then
        async.util.scheduler()
        out_status = ensure_output(2, { j }, context)
      end

      if out_status == JobStatus.ERROR then
        callback(j:stderr_result() or {}, nil)
        return
      end

      callback(nil, j:result())
    end),
  })
  -- Problem: Running multiple 'show' jobs simultaneously may cause them to fail
  -- silently.
  -- Solution: queue them and run them one after another.
  queue_sync_job(job)

end, 3)

M.JobStatus = JobStatus
return M
