local Commit = require("diffview.git.commit").Commit
local CountDownLatch = require("diffview.control").CountDownLatch
local FileDict = require("diffview.git.file_dict").FileDict
local FileEntry = require("diffview.views.file_entry").FileEntry
local Job = require("plenary.job")
local LogEntry = require("diffview.git.log_entry").LogEntry
local Rev = require("diffview.git.rev").Rev
local RevType = require("diffview.git.rev").RevType
local Semaphore = require("diffview.control").Semaphore
local async = require("plenary.async")
local config = require("diffview.config")
local logger = require("diffview.logger")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

local bootstrap = {
  done = false,
  ok = false,
  version_string = nil,
  version = {},
  target_version_string = nil,
  target_version = {
    major = 2,
    minor = 31,
    patch = 0,
  },
}

---@class JobStatus
---@field SUCCESS integer
---@field ERROR integer
---@field PROGRESS integer
---@field KILLED integer
---@field FATAL integer
local JobStatus = oop.enum({
  "SUCCESS",
  "PROGRESS",
  "ERROR",
  "KILLED",
  "FATAL",
})

---@type Job[]
local sync_jobs = {}
---@type Semaphore
local job_queue_sem = Semaphore.new(1)

---Ensure that the configured git binary meets the version requirement.
local function run_bootstrap()
  bootstrap.done = true
  local msg

  local out, code = utils.system_list(
    vim.tbl_flatten({ config.get_config().git_cmd, "version" })
  )

  if code ~= 0 or not out[1] then
    msg = "Could not run `git_cmd`!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  bootstrap.version_string = out[1]:match("git version (%S+)")

  if not bootstrap.version_string then
    msg = "Could not get git version!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  -- Parse git version
  local v, target = bootstrap.version, bootstrap.target_version
  bootstrap.target_version_string = ("%d.%d.%d"):format(target.major, target.minor, target.patch)
  local parts = vim.split(bootstrap.version_string, "%.")
  v.major = tonumber(parts[1])
  v.minor = tonumber(parts[2])
  v.patch = tonumber(parts[3]) or 0

  local vs = ("%08d%08d%08d"):format(v.major, v.minor, v.patch)
  local ts = ("%08d%08d%08d"):format(target.major, target.minor, target.patch)

  if vs < ts then
    msg = (
      "Git version is outdated! Some functionality might not work as expected, "
      .. "or not at all! Target: %s, current: %s"
    ):format(
      bootstrap.target_version_string,
      bootstrap.version_string
    )
    logger.error(msg)
    utils.err(msg)
    return
  end

  bootstrap.ok = true
end

---@return string cmd The git binary.
local function git_bin()
  return config.get_config().git_cmd[1]
end

---@return string[] args The default git args.
local function git_args()
  return utils.vec_slice(config.get_config().git_cmd, 2)
end

---Execute a git command synchronously.
---@param args string[]
---@param cwd_or_opt? string|SystemListSpec
---@return string[] stdout
---@return integer code
---@return string[] stderr
---@overload fun(args: string[], cwd: string?)
---@overload fun(args: string[], opt: SystemListSpec?)
function M.exec_sync(args, cwd_or_opt)
  if not bootstrap.done then
    run_bootstrap()
  end

  return utils.system_list(
    vim.tbl_flatten({ config.get_config().git_cmd, args }),
    cwd_or_opt
  )
end

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

---@param thread thread
---@param ok boolean
---@param result any
---@return boolean ok
---@return any result
local function handle_co(thread, ok, result)
  if not ok then
    local err_msg = utils.vec_join(
      "Coroutine failed!",
      debug.traceback(thread, result, 1)
    )
    utils.err(err_msg, true)
    logger.s_error(table.concat(err_msg, "\n"))
  end
  return ok, result
end

local tracked_files = async.wrap(function(git_root, left, right, args, kind, callback)
  ---@type FileEntry[]
  local files = {}
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
    command = git_bin(),
    args = utils.vec_join(git_args(), "diff", "--ignore-submodules", "--name-status", args),
    cwd = git_root,
    on_exit = on_exit
  })
  local numstat_job = Job:new({
    command = git_bin(),
    args = utils.vec_join(git_args(), "diff", "--ignore-submodules", "--numstat", args),
    cwd = git_root,
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

    table.insert(
      files,
      FileEntry({
        path = name,
        oldpath = oldname,
        absolute_path = utils.path:join(git_root, name),
        status = status,
        stats = stats,
        kind = kind,
        left = left,
        right = right,
      })
    )
  end

  callback(nil, files)
end, 6)

local untracked_files = async.wrap(function(git_root, left, right, callback)
  Job:new({
    command = git_bin(),
    args = utils.vec_join(git_args(), "ls-files", "--others", "--exclude-standard" ),
    cwd = git_root,
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
        table.insert(
          files,
          FileEntry({
            path = s,
            absolute_path = utils.path:join(git_root, s),
            status = "?",
            kind = "working",
            left = left,
            right = right,
          })
        )
      end
      callback(nil, files)
    end
  }):start()
end, 4)

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param opt DiffViewOptions
---@param callback function
---@return string[] err
---@return FileDict
M.diff_file_list = async.wrap(function(git_root, left, right, path_args, opt, callback)
  ---@type FileDict
  local files = FileDict()
  ---@type CountDownLatch
  local latch = CountDownLatch(2)
  local rev_args = M.rev_to_args(left, right)
  local errors = {}

  tracked_files(
    git_root,
    left,
    right,
    utils.vec_join(
      rev_args,
      "--",
      path_args
    ),
    "working",
    function (err, tfiles)
      if err then
        errors[#errors+1] = err
        utils.err("Failed to get git status for tracked files!", true)
        latch:count_down()
        return
      end

      files.working = tfiles
      local show_untracked = opt.show_untracked
      if show_untracked == nil then
        show_untracked = M.show_untracked(git_root)
      end

      if not (show_untracked and M.has_local(left, right)) then
        latch:count_down()
        return
      end

      ---@diagnostic disable-next-line: redefined-local
      local err, ufiles = untracked_files(git_root, left, right)
      if err then
        errors[#errors+1] = err
        utils.err("Failed to get git status for untracked files!", true)
        latch:count_down()
      else
        files.working = utils.vec_join(files.working, ufiles)

        utils.merge_sort(files.working, function(a, b)
          return a.path:lower() < b.path:lower()
        end)
        latch:count_down()
      end
    end
  )

  if not (left.type == RevType.INDEX and right.type == RevType.LOCAL) then
    latch:count_down()
  else
    local left_rev = M.head_rev(git_root) or Rev.new_null_tree()
    local right_rev = Rev(RevType.INDEX)
    tracked_files(
      git_root,
      left_rev,
      right_rev,
      utils.vec_join(
        "--cached",
        left_rev.commit,
        "--",
        path_args
      ),
      "staged",
      function(err, tfiles)
        if err then
          errors[#errors+1] = err
          utils.err("Failed to get git status for staged files!", true)
          latch:count_down()
          return
        end
        files.staged = tfiles
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
end, 6)

---@param log_options LogOptions
---@param single_file boolean
---@return string[]
local function prepare_fh_options(log_options, single_file)
  local o = log_options
  local line_trace = vim.tbl_map(function(v)
    if not v:match("^-L") then
      return "-L" .. v
    end
    return v
  end, o.L or {})

  return utils.vec_join(
    line_trace,
    (o.follow and single_file) and { "--follow" } or nil,
    o.first_parent and { "--first-parent" } or nil,
    o.show_pulls and { "--show-pulls" } or nil,
    o.reflog and { "--reflog" } or nil,
    o.all and { "--all" } or nil,
    o.merges and { "--merges" } or nil,
    o.no_merges and { "--no-merges" } or nil,
    o.reverse and { "--reverse" } or nil,
    o.max_count and { "-n" .. o.max_count } or nil,
    o.diff_merges and { "--diff-merges=" .. o.diff_merges } or nil,
    o.author and { "-E", "--author=" .. o.author } or nil,
    o.grep and { "-E", "--grep=" .. o.grep } or nil
  )
end

local function structure_fh_data(namestat_data, numstat_data)
  local right_hash, left_hash, merge_hash = unpack(utils.str_split(namestat_data[1]))
  local time, time_offset = unpack(utils.str_split(namestat_data[3]))

  return {
    left_hash = left_hash ~= "" and left_hash or nil,
    right_hash = right_hash,
    merge_hash = merge_hash,
    author = namestat_data[2],
    time = tonumber(time),
    time_offset = time_offset,
    rel_date = namestat_data[4],
    subject = namestat_data[5]:sub(3),
    namestat = utils.vec_slice(namestat_data, 6),
    numstat = numstat_data,
  }
end

---@param git_root string
---@param path_args string[]
---@param single_file boolean
---@param log_opt LogOptions
---@param callback fun(status: JobStatus, data?: table, msg?: string[])
local incremental_fh_data = async.void(function(git_root, path_args, single_file, log_opt, callback)
  local options = prepare_fh_options(log_opt, single_file)
  local raw = {}
  local namestat_job, numstat_job, shutdown

  local namestat_state = {
    data = {},
    key = "namestat",
    idx = 0,
  }
  local numstat_state = {
    data = {},
    key = "numstat",
    idx = 0,
  }

  local function on_stdout(_, line, j)
    local state = j == namestat_job and namestat_state or numstat_state

    if line == "\0" then
      if state.idx > 0 then
        if not raw[state.idx] then
          raw[state.idx] = {}
        end

        raw[state.idx][state.key] = state.data

        if not shutdown and raw[state.idx].namestat and raw[state.idx].numstat then
          shutdown = callback(
            JobStatus.PROGRESS,
            structure_fh_data(raw[state.idx].namestat, raw[state.idx].numstat)
          )

          if shutdown then
            logger.lvl(1).debug("Killing file history jobs...")
            -- NOTE: The default `Job:shutdown` methods use `vim.wait` which
            -- causes a segfault when called here.
            namestat_job:_shutdown(64)
            numstat_job:_shutdown(64)
          end
        end
      end
      state.idx = state.idx + 1
      state.data = {}
    elseif line ~= "" then
      table.insert(state.data, line)
    end
  end

  ---@type CountDownLatch
  local latch = CountDownLatch(2)

  local function on_exit(j, code)
    if code == 0 then
      on_stdout(nil, "\0", j)
    end
    latch:count_down()
  end

  namestat_job = Job:new({
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "log",
      log_opt.rev_range,
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n  %s",
      "--date=raw",
      "--name-status",
      options,
      "--",
      path_args
    ),
    cwd = git_root,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  numstat_job = Job:new({
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "log",
      log_opt.rev_range,
      "--pretty=format:%x00",
      "--date=raw",
      "--numstat",
      options,
      "--",
      path_args
    ),
    cwd = git_root,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  namestat_job:start()
  numstat_job:start()

  latch:await()

  local debug_opt = {
    context = "git.utils>incremental_fh_data()",
    func = "s_debug",
    debug_level = 1,
    no_stdout = true,
  }
  utils.handle_job(namestat_job, { debug_opt = debug_opt })
  utils.handle_job(numstat_job, { debug_opt = debug_opt })

  if shutdown then
    callback(JobStatus.KILLED)
  elseif namestat_job.code ~= 0 or numstat_job.code ~= 0 then
    callback(JobStatus.ERROR, nil, utils.vec_join(
      namestat_job:stderr_result(),
      numstat_job:stderr_result())
    )
  else
    callback(JobStatus.SUCCESS)
  end
end)

---@param git_root string
---@param log_opt LogOptions
---@param callback fun(status: JobStatus, data?: table, msg?: string[])
local incremental_line_trace_data = async.void(function(git_root, log_opt, callback)
  local options = prepare_fh_options(log_opt, true)
  local raw = {}
  local trace_job, shutdown

  local trace_state = {
    data = {},
    key = "trace",
    idx = 0,
  }

  local function on_stdout(_, line)
    if line == "\0" then
      if trace_state.idx > 0 then
        if not raw[trace_state.idx] then
          raw[trace_state.idx] = {}
        end

        raw[trace_state.idx] = trace_state.data

        if not shutdown then
          shutdown = callback(
            JobStatus.PROGRESS,
            structure_fh_data(raw[trace_state.idx])
          )

          if shutdown then
            logger.lvl(1).debug("Killing file history jobs...")
            -- NOTE: The default `Job:shutdown` methods use `vim.wait` which
            -- causes a segfault when called here.
            trace_job:_shutdown(64)
          end
        end
      end
      trace_state.idx = trace_state.idx + 1
      trace_state.data = {}
    elseif line ~= "" then
      table.insert(trace_state.data, line)
    end
  end

  ---@type CountDownLatch
  local latch = CountDownLatch(1)

  local function on_exit(_, code)
    if code == 0 then
      on_stdout(nil, "\0")
    end
    latch:count_down()
  end

  trace_job = Job:new({
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "-P",
      "log",
      log_opt.rev_range,
      "--color=never",
      "--no-ext-diff",
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n  %s",
      "--date=raw",
      options,
      "--"
    ),
    cwd = git_root,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  trace_job:start()

  latch:await()

  utils.handle_job(trace_job, {
    debug_opt = {
      context = "git.utils>incremental_line_trace_data()",
      func = "s_debug",
      debug_level = 1,
      no_stdout = true,
    }
  })

  if shutdown then
    callback(JobStatus.KILLED)
  elseif trace_job.code ~= 0 then
    callback(JobStatus.ERROR, nil, trace_job:stderr_result())
  else
    callback(JobStatus.SUCCESS)
  end
end)

---@param git_root string
---@param path_args string[]
---@param lflags string[]
---@return boolean
local function is_single_file(git_root, path_args, lflags)
  if lflags and #lflags > 0 then
    local seen = {}
    for i, v in ipairs(lflags) do
      local path = v:match(".*:(.*)")
      if i > 1 and not seen[path] then
        return false
      end
      seen[path] = true
    end

  elseif path_args and git_root then
    return #path_args == 1
        and not utils.path:is_directory(path_args[1])
        and #M.exec_sync({ "ls-files", "--", path_args }, git_root) < 2
  end

  return true
end

---@class git.utils.ParseFHDataSpec
---@field thread thread
---@field git_root string
---@field path_args string[]
---@field log_options LogOptions
---@field opt git.utils.FileHistoryWorkerSpec
---@field single_file boolean
---@field resume_lock boolean
---@field cur table
---@field commit Commit
---@field entries LogEntry[]
---@field callback function

---@param state git.utils.ParseFHDataSpec
---@return boolean ok, JobStatus status?
local function parse_fh_data(state)
  local cur, single_file, log_options, git_root, thread, path_args, callback, opt, commit, entries
      = state.cur, state.single_file, state.log_options, state.git_root, state.thread,
        state.path_args, state.callback, state.opt, state.commit, state.entries

  -- 'git log --name-status' doesn't work properly for merge commits. It
  -- lists only an incomplete list of files at best. We need to use 'git
  -- show' to get file statuses for merge commits. And merges do not always
  -- have changes.
  if cur.merge_hash and cur.numstat[1] and #cur.numstat ~= #cur.namestat then
    local job
    local job_spec = {
      command = git_bin(),
      args = utils.vec_join(
        git_args(),
        "show",
        "--format=",
        "--diff-merges=first-parent",
        "--name-status",
        (single_file and log_options.follow) and "--follow" or nil,
        cur.right_hash,
        "--",
        state.old_path or path_args
      ),
      cwd = git_root,
      on_exit = function(j)
        if j.code == 0 then
          cur.namestat = j:result()
        end
        handle_co(thread, coroutine.resume(thread))
      end,
    }

    local max_retries = 2
    local context = "git.utils.file_history_worker()"
    state.resume_lock = true

    for i = 0, max_retries do
      -- Git sometimes fails this job silently (exit code 0). Not sure why,
      -- possibly because we are running multiple git opeartions on the same
      -- repo concurrently. Retrying the job usually solves this.
      job = Job:new(job_spec)
      job:start()
      coroutine.yield()
      utils.handle_job(job, { fail_on_empty = true, context = context, log_func = logger.warn })

      if #cur.namestat == 0 then
        if i < max_retries then
          logger.warn(("[%s] Retrying %d more time(s)."):format(context, max_retries - i))
        end
      else
        if i > 0 then
          logger.info(("[%s] Retry successful!"):format(context))
        end
        break
      end
    end

    state.resume_lock = false

    if job.code ~= 0 then
      callback({}, JobStatus.ERROR, job:stderr_result())
      return false, JobStatus.FATAL
    end

    if #cur.namestat == 0 then
      -- Give up: something has been renamed. We can no longer track the
      -- history.
      logger.warn(("[%s] Giving up."):format(context))
      utils.warn("Displayed history may be incomplete. Check ':DiffviewLog' for details.", true)
      return false
    end
  end

  local files = {}
  for i = 1, #cur.numstat do
    local status = cur.namestat[i]:sub(1, 1):gsub("%s", " ")
    local name = cur.namestat[i]:match("[%a%s][^%s]*\t(.*)")
    local oldname

    if name:match("\t") ~= nil then
      oldname = name:match("(.*)\t")
      name = name:gsub("^.*\t", "")
      if single_file then
        state.old_path = oldname
      end
    end

    local stats = {
      additions = tonumber(cur.numstat[i]:match("^%d+")),
      deletions = tonumber(cur.numstat[i]:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end

    table.insert(
      files,
      FileEntry({
        path = name,
        oldpath = oldname,
        absolute_path = utils.path:join(git_root, name),
        status = status,
        stats = stats,
        kind = "working",
        commit = commit,
        left = cur.left_hash and Rev(RevType.COMMIT, cur.left_hash) or Rev.new_null_tree(),
        right = opt.base or Rev(RevType.COMMIT, cur.right_hash),
      })
    )
  end

  if files[1] then
    table.insert(
      entries,
      LogEntry({
        path_args = path_args,
        commit = commit,
        files = files,
        single_file = single_file,
      })
    )

    callback(entries, JobStatus.PROGRESS)
  end

  return true
end

---@param state git.utils.ParseFHDataSpec
---@return boolean ok
local function parse_fh_line_trace_data(state)
  local cur, single_file, git_root, path_args, callback, opt, commit, entries
      = state.cur, state.single_file, state.git_root, state.path_args, state.callback,
        state.opt, state.commit, state.entries

  local files = {}

  for _, line in ipairs(cur.namestat) do
    if line:match("^diff %-%-git ") then
      local a_path = line:match('^diff %-%-git "?a/(.-)"? "?b/')
      local b_path = line:match('.*"? "?b/(.-)"?$')
      local oldpath = a_path ~= b_path and a_path or nil

      if single_file and oldpath then
        state.old_path = oldpath
      end

      table.insert(
        files,
        FileEntry({
          path = b_path,
          oldpath = oldpath,
          absolute_path = utils.path:join(git_root, b_path),
          kind = "working",
          commit = commit,
          left = cur.left_hash and Rev(RevType.COMMIT, cur.left_hash) or Rev.new_null_tree(),
          right = opt.base or Rev(RevType.COMMIT, cur.right_hash),
        })
      )
    end
  end

  if files[1] then
    table.insert(
      entries,
      LogEntry({
        path_args = path_args,
        commit = commit,
        files = files,
        single_file = single_file,
      })
    )

    callback(entries, JobStatus.PROGRESS)
  end

  return true
end

---@class git.utils.FileHistoryWorkerSpec
---@field base Rev

---@param thread thread
---@param git_root string
---@param path_args string[]
---@param log_opt ConfigLogOptions
---@param opt git.utils.FileHistoryWorkerSpec
---@param co_state table
---@param callback function
local function file_history_worker(thread, git_root, path_args, log_opt, opt, co_state, callback)
  ---@type LogEntry[]
  local entries = {}
  local data = {}
  local data_idx = 1
  local last_status
  local err_msg

  local single_file = is_single_file(git_root, path_args, log_opt.single_file.L)

  ---@type LogOptions
  local log_options = config.get_log_options(
    single_file,
    single_file and log_opt.single_file or log_opt.multi_file
  )

  local is_trace = #log_options.L > 0

  ---@type git.utils.ParseFHDataSpec
  local state = {
    thread = thread,
    git_root = git_root,
    path_args = path_args,
    log_options = log_options,
    opt = opt,
    callback = callback,
    entries = entries,
    single_file = single_file,
    resume_lock = false,
  }

  local function data_callback(status, d, msg)
    if status == JobStatus.PROGRESS then
      data[#data+1] = d
    end

    last_status = status
    if msg then
      err_msg = msg
    end
    if not state.resume_lock and coroutine.status(thread) == "suspended" then
      handle_co(thread, coroutine.resume(thread))
    end

    if co_state.shutdown then
      return true
    end
  end

  if is_trace then
    incremental_line_trace_data(git_root, log_options, data_callback)
  else
    incremental_fh_data(git_root, path_args, single_file, log_options, data_callback)
  end

  while true do
    if not vim.tbl_contains({ JobStatus.SUCCESS, JobStatus.ERROR, JobStatus.KILLED }, last_status)
        and not data[data_idx] then
      coroutine.yield()
    end

    if last_status == JobStatus.KILLED then
      logger.lvl(1).debug("File history processing was killed.")
      return
    elseif last_status == JobStatus.ERROR then
      callback(entries, JobStatus.ERROR, err_msg)
      return
    elseif last_status == JobStatus.SUCCESS and data_idx > #data then
      break
    end

    state.cur = data[data_idx]

    state.commit = Commit({
      hash = state.cur.right_hash,
      author = state.cur.author,
      time = tonumber(state.cur.time),
      time_offset = state.cur.time_offset,
      rel_date = state.cur.rel_date,
      subject = state.cur.subject,
    })

    local ok, status
    if log_options.L[1] then
      ok, status = parse_fh_line_trace_data(state)
    else
      ok, status = parse_fh_data(state)
    end

    if not ok then
      if status == JobStatus.FATAL then
        return
      end
      break
    end

    data_idx = data_idx + 1
  end

  callback(entries, JobStatus.SUCCESS)
end

---@param git_root string
---@param path_args string[]
---@param log_opt ConfigLogOptions
---@param opt git.utils.FileHistoryWorkerSpec
---@param callback function
---@return fun() finalizer
function M.file_history(git_root, path_args, log_opt, opt, callback)
  local thread

  local co_state = {
    shutdown = false,
  }

  thread = coroutine.create(function()
    file_history_worker(thread, git_root, path_args, log_opt, opt, co_state, callback)
  end)

  handle_co(thread, coroutine.resume(thread))

  return function()
    co_state.shutdown = true
  end
end

---@param git_root string
---@param path_args string[]
---@param log_opt LogOptions
---@return boolean ok, string description
function M.file_history_dry_run(git_root, path_args, log_opt)
  local single_file = is_single_file(git_root, path_args, log_opt.L)
  local log_options = config.get_log_options(single_file, log_opt)

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, prepare_fh_options(log_options, single_file))

  local description = utils.vec_join(
    ("Top-level path: '%s'"):format(utils.path:vim_fnamemodify(git_root, ":~")),
    log_options.rev_range and ("Revision range: '%s'"):format(log_options.rev_range) or nil,
    ("Flags: %s"):format(table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options)
  log_options.max_count = 1
  options = prepare_fh_options(log_options, single_file)

  local context = "git.utils.file_history_dry_run()"
  local cmd

  if #log_options.L > 0 then
    -- cmd = utils.vec_join("-P", "log", "--no-ext-diff", "--color=never", "--pretty=format:%H", "-s", options, log_options.rev_range, "--")
    -- NOTE: Running the dry-run for line tracing is slow. Just skip for now.
    return true, table.concat(description, ", ")
  else
    cmd = utils.vec_join("log", "--pretty=format:%H", "--name-status", options, log_options.rev_range, "--", path_args)
  end

  local out, code = M.exec_sync(cmd, {
    cwd = git_root,
    debug_opt = {
      context = context,
      no_stdout = true,
    },
  })

  local ok = code == 0 and #out > 0

  if not ok then
    logger.lvl(1).s_debug(("[%s] Dry run failed."):format(context))
  end

  return ok, table.concat(description, ", ")
end

---Determine whether a rev arg is a range.
---@param rev_arg string
---@return boolean
function M.is_rev_arg_range(rev_arg)
  return utils.str_match(rev_arg, {
    "^%.%.%.?$",
    "^%.%.%.?[^.]",
    "[^.]%.%.%.?$",
    "[^.]%.%.%.?[^.]",
    "^.-%^@",
    "^.-%^!",
    "^.-%^%-%d?",
  }) ~= nil
end

---Convert revs to git rev args.
---@param left Rev
---@param right Rev
---@return string[]
function M.rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { left.commit .. ".." .. right.commit }
  elseif left.type == RevType.INDEX and right.type == RevType.LOCAL then
    return {}
  elseif left.type == RevType.COMMIT and right.type == RevType.INDEX then
    return { "--cached", left.commit }
  else
    return { left.commit }
  end
end

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function M.rev_to_pretty_string(left, right)
  if left.track_head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

---@param git_root string
---@return Rev
function M.head_rev(git_root)
  local out, code = M.exec_sync(
    { "rev-parse", "HEAD", "--" },
    { cwd = git_root, retry_on_empty = 2 }
  )
  if code ~= 0 then
    return
  end
  local s = vim.trim(out[1]):gsub("^%^", "")
  return Rev(RevType.COMMIT, s, true)
end

---Parse two endpoint, commit revs from a symmetric difference notated rev arg.
---@param git_root string
---@param rev_arg string
---@return Rev left The left rev.
---@return Rev right The right rev.
function M.symmetric_diff_revs(git_root, rev_arg)
  local r1 = rev_arg:match("(.+)%.%.%.") or "HEAD"
  local r2 = rev_arg:match("%.%.%.(.+)") or "HEAD"
  local out, code, stderr

  local function err()
    utils.err(utils.vec_join(
      ("Failed to parse rev '%s'!"):format(rev_arg),
      "Git output: ",
      stderr
    ))
  end

  out, code, stderr = M.exec_sync({ "merge-base", r1, r2 }, git_root)
  if code ~= 0 then
    return err()
  end
  local left_hash = out[1]:gsub("^%^", "")

  out, code, stderr = M.exec_sync({ "rev-parse", "--revs-only", r2 }, git_root)
  if code ~= 0 then
    return err()
  end
  local right_hash = out[1]:gsub("^%^", "")

  return Rev(RevType.COMMIT, left_hash), Rev(RevType.COMMIT, right_hash)
end

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.toplevel(path)
  local out, code = M.exec_sync({ "rev-parse", "--path-format=absolute", "--show-toplevel" }, path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

---Get the path to the .git directory.
---@param path string
---@return string|nil
function M.git_dir(path)
  local out, code = M.exec_sync({ "rev-parse", "--path-format=absolute", "--git-dir" }, path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

M.show = async.wrap(function(git_root, args, callback)
  local job = Job:new({
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "show",
      args
    ),
    cwd = git_root,
    ---@type Job
    on_exit = async.void(function(j)
      if j.code ~= 0 then
        utils.handle_job(j)
        callback(j:stderr_result() or {}, nil)
        return
      end

      local out_status

      if #j:result() == 0 then
        async.util.scheduler()
        out_status = ensure_output(2, { j }, "git.utils.show()")
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

---@return string, string
function M.pathspec_split(pathspec)
  local magic = pathspec:match("^:[/!^]*:?") or pathspec:match("^:%b()") or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic or "", pattern or ""
end

function M.pathspec_expand(git_root, cwd, pathspec)
  local magic, pattern = M.pathspec_split(pathspec)
  if not utils.path:is_abs(pattern) then
    pattern = utils.path:join(utils.path:relative(cwd, git_root), pattern)
  end
  return magic .. utils.path:convert(pattern)
end

function M.pathspec_modify(pathspec, mods)
  local magic, pattern = M.pathspec_split(pathspec)
  return magic .. utils.path:vim_fnamemodify(pattern, mods)
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function M.has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---Strange trick to check if a file is binary using only git.
---@param git_root string
---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function M.is_binary(git_root, path, rev)
  local cmd = { "-c", "submodule.recurse=false", "grep", "-I", "--name-only", "-e", "." }
  if rev.type == RevType.LOCAL then
    cmd[#cmd+1] = "--untracked"
  elseif rev.type == RevType.INDEX then
    cmd[#cmd+1] = "--cached"
  else
    cmd[#cmd+1] = rev.commit
  end

  utils.vec_push(cmd, "--", path)

  local _, code = M.exec_sync(cmd, { cwd = git_root, silent = true })
  return code ~= 0
end

---Check if status for untracked files is disabled for a given git repo.
---@param git_root string
---@return boolean
function M.show_untracked(git_root)
  local out = M.exec_sync(
    { "config", "--type=bool", "status.showUntrackedFiles" },
    { cwd = git_root, silent = true }
  )
  return vim.trim(out[1] or "") ~= "false"
end

---Get the diff status letter for a file for a given rev.
---@param git_root string
---@param path string
---@param rev_arg string
---@return string?
function M.get_file_status(git_root, path, rev_arg)
  local out, code = M.exec_sync(
    { "diff", "--name-status", rev_arg, "--", path },
    git_root
  )
  if code == 0 and (out[1] and #out[1] > 0) then
    return out[1]:sub(1, 1)
  end
end

---Get diff stats for a file for a given rev.
---@param git_root string
---@param path string
---@param rev_arg string
---@return GitStats
function M.get_file_stats(git_root, path, rev_arg)
  local out, code = M.exec_sync({ "diff", "--numstat", rev_arg, "--", path }, git_root)
  if code == 0 and (out[1] and #out[1] > 0) then
    local stats = {
      additions = tonumber(out[1]:match("^%d+")),
      deletions = tonumber(out[1]:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end
    return stats
  end
end

---Verify that a given git rev is valid.
---@param git_root string
---@param rev_arg string
---@return boolean ok, string[] output
function M.verify_rev_arg(git_root, rev_arg)
  local out, code = M.exec_sync({ "rev-parse", "--revs-only", rev_arg }, git_root)
  return code == 0 and out[1] and out[1] ~= "", out
end

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param git_root string
---@param path string
---@param kind '"staged"'|'"working"'
---@param commit string
M.restore_file = async.wrap(function(git_root, path, kind, commit, callback)
  local out, code
  local abs_path = utils.path:join(git_root, path)
  local rel_path = utils.path:vim_fnamemodify(abs_path, ":~")

  -- Check if file exists in history
  _, code = M.exec_sync(
    { "cat-file", "-e", ("%s:%s"):format(kind == "staged" and "HEAD" or "", path) },
    git_root
  )
  local exists_git = code == 0
  local exists_local = utils.path:readable(abs_path)

  if exists_local then
    -- Wite file blob into db
    out, code = M.exec_sync({ "hash-object", "-w", "--", path }, git_root)
    if code ~= 0 then
      utils.err("Failed to write file blob into the object database. Aborting file restoration.", true)
      return callback()
    end
  end

  local undo
  if exists_local then
    undo = (":sp %s | %%!git show %s"):format(vim.fn.fnameescape(rel_path), out[1]:sub(1, 11))
  else
    undo = (":!git rm %s"):format(vim.fn.fnameescape(path))
  end

  -- Revert file
  if not exists_git then
    local bn = utils.find_file_buffer(abs_path)
    if bn then
      async.util.scheduler()
      local ok, err = utils.remove_buffer(false, bn)
      if not ok then
        utils.err({
          ("Failed to delete buffer '%d'! Aborting file restoration. Error message:")
            :format(bn),
          err
        }, true)
        return callback()
      end
    end

    if kind == "working" then
      -- File is untracked and has no history: delete it from fs.
      local ok, err = utils.path:unlink(abs_path)
      if not ok then
        utils.err({
          ("Failed to delete file '%s'! Aborting file restoration. Error message:")
            :format(abs_path),
          err
        }, true)
        return callback()
      end
    else
      -- File only exists in index
      out, code = M.exec_sync(
        { "rm", "-f", "--", path },
        git_root
      )
    end
  else
    -- File exists in history: checkout
    out, code = M.exec_sync(
      utils.vec_join("checkout", commit or (kind == "staged" and "HEAD" or nil), "--", path),
      git_root
    )
  end
  if code ~= 0 then
    utils.err("Failed to revert file! See ':DiffviewLog' for details.", true)
    return callback()
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == "staged" and "HEAD" or "index")
  utils.info(("File restored from %s. Undo with %s"):format(rev_name, undo), true)
  callback()
end, 5)

M.JobStatus = JobStatus
return M
