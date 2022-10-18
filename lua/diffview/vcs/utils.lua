local utils = require("diffview.utils")
local async = require("plenary.async")
local Job = require("plenary.job")

local M = {}

---@enum JobStatus
local JobStatus = {
  SUCCESS = 1,
  PROGRESS = 2,
  ERROR = 3,
  KILLED = 4,
  FATAL = 5,
}

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
