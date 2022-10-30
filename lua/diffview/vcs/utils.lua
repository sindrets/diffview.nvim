local CountDownLatch = require("diffview.control").CountDownLatch
local utils = require("diffview.utils")
local async = require("plenary.async")
local logger = require("diffview.logger")
local FileDict = require("diffview.vcs.file_dict").FileDict
local FileEntry = require("diffview.scene.file_entry").FileEntry
local RevType = require("diffview.vcs.rev").RevType
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

---@param max_retries integer
---@vararg Job
local ensure_output = async.wrap(function(max_retries, jobs, log_context, callback)
  local num_bad_jobs
  local num_retries = 0
  local new_jobs = {}
  local context = log_context and ("[%s] "):format(log_context) or ""

  for n = 0, max_retries - 1 do
    num_bad_jobs = 0
    for i, job in ipairs(jobs) do

      if job.code == 0 and #job:result() == 0 then
        logger.warn(
          ("%sJob expected output, but returned nothing! Retrying %d more times(s)...")
          :format(context, max_retries - n)
        )
        logger.log_job(job, { func = logger.warn, context = log_context })
        num_retries = n + 1

        new_jobs[i] = Job:new({
          command = job.command,
          args = job.args,
          cwd = job._raw_cwd,
          env = job.env,
        })
        new_jobs[i]:start()
        if vim.in_fast_event() then
          async.util.scheduler()
        end
        Job.join(new_jobs[i])

        job._stdout_results = new_jobs[i]._stdout_results
        job._stderr_results = new_jobs[i]._stderr_results

        if new_jobs[i].code ~= 0 then
          job.code = new_jobs[i].code
          utils.handle_job(new_jobs[i], { context = log_context })
        elseif #job._stdout_results == 0 then
          num_bad_jobs = num_bad_jobs + 1
        end
      end
    end

    if num_bad_jobs == 0 then
      if num_retries > 0 then
        logger.s_info(("%sRetry was successful!"):format(context))
      end
      callback(JobStatus.SUCCESS)
      return
    end
  end

  callback(JobStatus.ERROR)
end, 4)

M.show = async.wrap(function(adapter, args, callback) 
  local job = Job:new({
    command = adapter:bin(),
    args = adapter:get_show_args(args),
    cwd = adapter.ctx.toplevel,
    ---@type Job
    on_exit = async.void(function(j)
      local context = "vcs.utils.show()"
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

---@param adapter VCSAdapter
---@param left Rev
---@param right Rev
---@param args string[]
---@param kind git.FileKind
---@param opt git.utils.LayoutOpt
---@param callback function
local tracked_files = async.wrap(function(adapter, left, right, args, kind, opt, callback)
  ---@type FileEntry[]
  local files = {}
  ---@type FileEntry[]
  local conflicts = {}
  ---@type CountDownLatch
  local latch = CountDownLatch(2)
  local debug_opt = {
    context = "git.utils>tracked_files()",
    func = "s_debug",
    debug_level = 1,
    no_stdout = true,
  }

  ---@param job Job
  local function on_exit(job)
    utils.handle_job(job, { debug_opt = debug_opt })
    latch:count_down()
  end

  local namestat_job = Job:new({
    command = adapter:bin(),
    args = adapter:get_namestat_args(args),
    cwd = adapter.ctx.toplevel,
    on_exit = on_exit
  })
  local numstat_job = Job:new({
    command = adapter:bin(),
    args = adapter:get_numstat_args(args),
    cwd = adapter.ctx.toplevel,
    on_exit = on_exit
  })

  namestat_job:start()
  numstat_job:start()
  latch:await()
  local out_status
  if not (#namestat_job:result() == #numstat_job:result()) then
    out_status = ensure_output(2, { namestat_job, numstat_job }, "git.utils>tracked_files()")
  end

  if out_status == JobStatus.ERROR or not (namestat_job.code == 0 and numstat_job.code == 0) then
    callback(utils.vec_join(namestat_job:stderr_result(), numstat_job:stderr_result()), nil)
    return
  end

  local numstat_out = numstat_job:result()
  local data = {}
  local conflict_map = {}

  for i, s in ipairs(namestat_job:result()) do
    local status = s:sub(1, 1):gsub("%s", " ")
    local name = s:match("[%a%s][^%s]*\t(.*)")
    local oldname

    if name:match("\t") ~= nil then
      oldname = name:match("(.*)\t")
      name = name:gsub("^.*\t", "")
    end

    local stats = {
      additions = tonumber(numstat_out[i]:match("^%d+")),
      deletions = tonumber(numstat_out[i]:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end

    if not (status == "U" and kind == "staged") then
      table.insert(data, {
        status = status,
        name = name,
        oldname = oldname,
        stats = stats,
      })
    end

    if status == "U" then
      conflict_map[name] = data[#data]
    end
  end

  if kind == "working" and next(conflict_map) then
    data = vim.tbl_filter(function(v)
      return not conflict_map[v.name]
    end, data)

    for _, v in pairs(conflict_map) do
      table.insert(conflicts, FileEntry.with_layout(opt.merge_layout, {
        adapter = adapter,
        path = v.name,
        oldpath = v.oldname,
        status = "U",
        kind = "conflicting",
        rev_ours = adapter.Rev(RevType.STAGE, 2),
        rev_main = adapter.Rev(RevType.LOCAL),
        rev_theirs = adapter.Rev(RevType.STAGE, 3),
        rev_base = adapter.Rev(RevType.STAGE, 1),
      }))
    end
  end

  for _, v in ipairs(data) do
    table.insert(files, FileEntry.for_d2(opt.default_layout, {
      adapter = adapter,
      path = v.name,
      oldpath = v.oldname,
      status = v.status,
      stats = v.stats,
      kind = kind,
      rev_a = left,
      rev_b = right,
    }))
  end

  callback(nil, files, conflicts)
end, 7)

---@param adapter VCSAdapter
---@param left Rev
---@param right Rev
---@param opt git.utils.LayoutOpt
---@param callback function
local untracked_files = async.wrap(function(adapter, left, right, opt, callback)
  Job:new({
    command = adapter:bin(),
    args = adapter:get_files_args(),
    cwd = adapter.ctx.toplevel,
    ---@type Job
    on_exit = function(j)
      utils.handle_job(j, {
        debug_opt = {
          context = "git.utils>untracked_files()",
          func = "s_debug",
          debug_level = 1,
          no_stdout = true,
        }
      })

      if j.code ~= 0 then
        callback(j:stderr_result() or {}, nil)
        return
      end

      local files = {}
      for _, s in ipairs(j:result()) do
        table.insert(files, FileEntry.for_d2(opt.default_layout, {
          adapter = adapter,
          path = s,
          status = "?",
          kind = "working",
          rev_a = left,
          rev_b = right,
        }))
      end
      callback(nil, files)
    end
  }):start()
end, 5)

---Get a list of files modified between two revs.
---@param adapter VCSAdapter
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param dv_opt DiffViewOptions
---@param opt git.utils.LayoutOpt
---@param callback function
---@return string[]? err
---@return FileDict?
M.diff_file_list = async.wrap(function(adapter, left, right, path_args, dv_opt, opt, callback)
  ---@type FileDict
  local files = FileDict()
  ---@type CountDownLatch
  local latch = CountDownLatch(2)
  local rev_args = adapter:rev_to_args(left, right)
  local errors = {}

  tracked_files(
    adapter,
    left,
    right,
    utils.vec_join(
      rev_args,
      "--",
      path_args
    ),
    "working",
    opt,
    function (err, tfiles, tconflicts)
      if err then
        errors[#errors+1] = err
        utils.err("Failed to get git status for tracked files!", true)
        latch:count_down()
        return
      end

      files:set_working(tfiles)
      files:set_conflicting(tconflicts)
      local show_untracked = dv_opt.show_untracked

      if show_untracked == nil then
        show_untracked = adapter:show_untracked()
      end

      if not (show_untracked and adapter:has_local(left, right)) then
        latch:count_down()
        return
      end

      ---@diagnostic disable-next-line: redefined-local
      local err, ufiles = untracked_files(adapter, left, right, opt)
      if err then
        errors[#errors+1] = err
        utils.err("Failed to get git status for untracked files!", true)
        latch:count_down()
      else
        files:set_working(utils.vec_join(files.working, ufiles))

        utils.merge_sort(files.working, function(a, b)
          return a.path:lower() < b.path:lower()
        end)
        latch:count_down()
      end
    end
  )

  if not (left.type == RevType.STAGE and right.type == RevType.LOCAL) then
    latch:count_down()
  else
    local left_rev = adapter:head_rev() or adapter.Rev.new_null_tree()
    local right_rev = adapter.Rev(RevType.STAGE, 0)
    tracked_files(
      adapter,
      left_rev,
      right_rev,
      utils.vec_join(
        "--cached",
        left_rev.commit,
        "--",
        path_args
      ),
      "staged",
      opt,
      function(err, tfiles)
        if err then
          errors[#errors+1] = err
          utils.err("Failed to get git status for staged files!", true)
          latch:count_down()
          return
        end
        files:set_staged(tfiles)
        latch:count_down()
      end
    )
  end

  latch:await()
  if #errors > 0 then
    callback(utils.vec_join(unpack(errors)), nil)
    return
  end

  files:update_file_trees()
  callback(nil, files)
end, 7)


---@param arg_lead string
---@param items string[]
---@return string[]
function M.filter_completion(arg_lead, items)
  arg_lead, _ = vim.pesc(arg_lead)
  return vim.tbl_filter(function(item)
    return item:match(arg_lead)
  end, items)
end

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param adapter VCSAdapter
---@param path string
---@param kind '"staged"'|'"working"'
---@param commit string
M.restore_file = async.wrap(function(adapter, path, kind, commit, callback)
  local undo = adapter:file_restore(path, kind, commit)
  if not undo then
    utils.err("Failed to revert file! See ':DiffviewLog' for details.", true)
    return callback()
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == "staged" and "HEAD" or "index")
  utils.info(("File restored from %s. Undo with %s"):format(rev_name, undo), true)
  callback()
end, 5)


M.JobStatus = JobStatus
return M
