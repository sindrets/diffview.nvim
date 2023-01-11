local Commit = require("diffview.vcs.adapters.git.commit").GitCommit
local CountDownLatch = require("diffview.control").CountDownLatch
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileEntry = require("diffview.scene.file_entry").FileEntry
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local Job = require("plenary.job")
local JobStatus = require("diffview.vcs.utils").JobStatus
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local RevType = require("diffview.vcs.rev").RevType
local VCSAdapter = require("diffview.vcs.adapter").VCSAdapter
local arg_parser = require("diffview.arg_parser")
local async = require("plenary.async")
local config = require("diffview.config")
local diffview = require("diffview")
local lazy = require("diffview.lazy")
local logger = require("diffview.logger")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local vcs_utils = require("diffview.vcs.utils")

---@type PathLib
local pl = lazy.access(utils, "path")
local api = vim.api

local M = {}

---@class GitAdapter : VCSAdapter
local GitAdapter = oop.create_class("GitAdapter", VCSAdapter)

GitAdapter.Rev = GitRev
GitAdapter.config_key = "git"

---@return string, string
function M.pathspec_split(pathspec)
  local magic = utils.str_match(pathspec, {
    "^:[/!^]+:?",
    "^:%b()",
    "^:",
  }) or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic or "", pattern or ""
end

function M.pathspec_expand(toplevel, cwd, pathspec)
  local magic, pattern = M.pathspec_split(pathspec)
  if not utils.path:is_abs(pattern) then
    pattern = utils.path:join(utils.path:relative(cwd, toplevel), pattern)
  end
  return magic .. utils.path:convert(pattern)
end

function M.pathspec_modify(pathspec, mods)
  local magic, pattern = M.pathspec_split(pathspec)
  return magic .. utils.path:vim_fnamemodify(pattern, mods)
end

---@param path_args string[] # Raw path args
---@param cpath string? # Cwd path given by the `-C` flag option
---@return string[] path_args # Resolved path args
---@return string[] top_indicators # Top-level indicators
function M.get_repo_paths(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  for _, path_arg in ipairs(path_args) do
    for _, path in ipairs(pl:vim_expand(path_arg, false, true)) do
      local magic, pattern = M.pathspec_split(path)
      pattern = pl:readlink(pattern) or pattern
      table.insert(paths, magic .. pattern)
    end
  end

  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  for _, path in ipairs(paths) do
    if M.pathspec_split(path) == "" then
      table.insert(top_indicators, pl:absolute(path, cpath))
      break
    end
  end

  table.insert(top_indicators, cpath and pl:realpath(cpath) or (
    vim.bo.buftype == ""
    and pl:absolute(cfile)
    or nil
  ))

  if not cpath then
    table.insert(top_indicators, pl:realpath("."))
  end

  return paths, top_indicators
end

---Get the git toplevel directory from a path to file or directory
---@param path string
---@return string?
local function get_toplevel(path)
  local out, code = utils.system_list(vim.tbl_flatten({
    config.get_config().git_cmd,
    { "rev-parse", "--path-format=absolute", "--show-toplevel" },
  }), path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

---Try to find the top-level of a working tree by using the given indicative
---paths.
---@param top_indicators string[] A list of paths that might indicate what working tree we are in.
---@return string? err
---@return string toplevel # as an absolute path
function M.find_toplevel(top_indicators)
  local toplevel
  for _, p in ipairs(top_indicators) do
    if not pl:is_dir(p) then
      p = pl:parent(p)
    end

    if p and pl:readable(p) then
      toplevel = get_toplevel(p)
      if toplevel then
        return nil, toplevel
      end
    end
  end

  return (
    ("Path not a git repo (or any parent): %s")
    :format(table.concat(vim.tbl_map(function(v)
      local rel_path = pl:relative(v, ".")
      return utils.str_quote(rel_path == "" and "." or rel_path)
    end, top_indicators) --[[@as vector ]], ", "))
  ), ""
end

---@param toplevel string
---@param path_args string[]
---@param cpath string?
---@return GitAdapter
function M.create(toplevel, path_args, cpath)
  return GitAdapter({
    toplevel = toplevel,
    path_args = path_args,
    cpath = cpath,
  })
end

---@param opt vcs.adapter.VCSAdapter.Opt
function GitAdapter:init(opt)
  opt = opt or {}
  GitAdapter:super().init(self, opt)

  self.bootstrap.target_version = {
    major = 2,
    minor = 31,
    patch = 0,
  }

  local cwd = opt.cpath or vim.loop.cwd()

  self.ctx = {
    toplevel = opt.toplevel,
    dir = self:get_dir(opt.toplevel),
    path_args = vim.tbl_map(function(pathspec)
      return M.pathspec_expand(opt.toplevel, cwd, pathspec)
    end, opt.path_args or {}) --[[@as string[] ]]
  }

  self:init_completion()
end

function GitAdapter:run_bootstrap()
  local msg
  self.bootstrap.done = true

  local out, code = utils.system_list(vim.tbl_flatten({ config.get_config().git_cmd, "version" }))
  if code ~= 0 or not out[1] then
    msg = "Could not run `git_cmd`!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  self.bootstrap.version_string = out[1]:match("git version (%S+)")

  if not self.bootstrap.version_string then
    msg = "Could not get git version!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  -- Parse git version
  local v, target = self.bootstrap.version, self.bootstrap.target_version
  self.bootstrap.target_version_string = ("%d.%d.%d"):format(target.major, target.minor, target.patch)
  local parts = vim.split(self.bootstrap.version_string, "%.")
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
      self.bootstrap.target_version_string,
      self.bootstrap.version_string
    )
    logger.error(msg)
    utils.err(msg)
    return
  end

  self.bootstrap.ok = true
end

function GitAdapter:get_command()
  return config.get_config().git_cmd
end

---@param path string
---@param rev Rev?
function GitAdapter:get_show_args(path, rev)
  return utils.vec_join(self:args(), "show", ("%s:%s"):format(rev and rev:object_name() or "", path))
end

function GitAdapter:get_log_args(args)
  return utils.vec_join("log", "--first-parent", "--stat", args)
end

function GitAdapter:get_dir(path)
  local out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--git-dir" }, path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

---Verify that a given git rev is valid.
---@param rev_arg string
---@return boolean ok, string[] output
function GitAdapter:verify_rev_arg(rev_arg)
  local out, code = self:exec_sync({ "rev-parse", "--revs-only", rev_arg }, {
    context = "GitAdapter.verify_rev_arg()",
    cwd = self.ctx.toplevel,
  })
  return code == 0 and (out[2] ~= nil or out[1] and out[1] ~= ""), out
end

---@return vcs.MergeContext
function GitAdapter:get_merge_context()
  local their_head

  for _, name in ipairs({ "MERGE_HEAD", "REBASE_HEAD", "REVERT_HEAD" }) do
    if pl:readable(pl:join(self.ctx.dir, name)) then
      their_head = name
      break
    end
  end

  assert(their_head)
  local ret = {}
  local out, code = self:exec_sync({ "show", "-s", "--pretty=format:%H%n%D", "HEAD", "--" }, self.ctx.toplevel)

  ret.ours = code ~= 0 and {} or  {
    hash = out[1],
    ref_names = out[2],
  }

  out, code = self:exec_sync({ "show", "-s", "--pretty=format:%H%n%D", their_head, "--" }, self.ctx.toplevel)

  ret.theirs = code ~= 0 and {} or  {
    hash = out[1],
    rev_names = out[2],
  }

  out, code = self:exec_sync({ "merge-base", "HEAD", their_head }, self.ctx.toplevel)
  assert(code == 0)

  ret.base = {
    hash = out[1],
    ref_names = self:exec_sync({ "show", "-s", "--pretty=format:%D" }, self.ctx.toplevel)[1],
  }

  return ret
end

---@class GitAdapter.PreparedLogOpts
---@field rev_range string
---@field base Rev
---@field path_args string[]
---@field flags string[]

---@param adapter GitAdapter
---@param log_options GitLogOptions
---@param single_file boolean
---@return GitAdapter.PreparedLogOpts
local function prepare_fh_options(adapter, log_options, single_file)
  local o = log_options
  local line_trace = vim.tbl_map(function(v)
    if not v:match("^-L") then
      return "-L" .. v
    end
    return v
  end, o.L or {})

  local rev_range, base

  if log_options.rev_range then
    local ok, _ = adapter:verify_rev_arg(log_options.rev_range)

    if not ok then
      utils.warn(("Bad range revision, ignoring: %s"):format(utils.str_quote(log_options.rev_range)))
    else
      rev_range = log_options.rev_range
    end
  end

  if log_options.base then
    if log_options.base == "LOCAL" then
      base = GitRev(RevType.LOCAL)
    else
      local ok, out = adapter:verify_rev_arg(log_options.base)

      if not ok then
        utils.warn(("Bad base revision, ignoring: %s"):format(utils.str_quote(log_options.base)))
      else
        base = GitRev(RevType.COMMIT, out[1])
      end
    end
  end

  return {
    rev_range = rev_range,
    base = base,
    path_args = log_options.path_args,
    flags = utils.vec_join(
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
      o.grep and { "-E", "--grep=" .. o.grep } or nil,
      o.G and { "-E", "-G" .. o.G } or nil,
      o.S and { "-S" .. o.S, "--pickaxe-regex" } or nil
    )
  }
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
    ref_names = namestat_data[5]:sub(3),
    subject = namestat_data[6]:sub(3),
    namestat = utils.vec_slice(namestat_data, 7),
    numstat = numstat_data,
  }
end

---@param state GitAdapter.FHState
---@param callback fun(status: JobStatus, data?: table, msg?: string[])
local incremental_fh_data = async.void(function(state, callback)
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
    local handler_state = j == namestat_job and namestat_state or numstat_state

    if line == "\0" then
      if handler_state.idx > 0 then
        if not raw[handler_state.idx] then
          raw[handler_state.idx] = {}
        end

        raw[handler_state.idx][handler_state.key] = handler_state.data

        if not shutdown and raw[handler_state.idx].namestat and raw[handler_state.idx].numstat then
          shutdown = callback(
            JobStatus.PROGRESS,
            structure_fh_data(raw[handler_state.idx].namestat, raw[handler_state.idx].numstat)
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
      handler_state.idx = handler_state.idx + 1
      handler_state.data = {}
    elseif line ~= "" then
      table.insert(handler_state.data, line)
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

  local rev_range = state.prepared_log_opts.rev_range

  namestat_job = Job:new({
    command = state.adapter:bin(),
    args = utils.vec_join(
      state.adapter:args(),
      "log",
      rev_range,
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n  %D%n  %s",
      "--date=raw",
      "--name-status",
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = state.adapter.ctx.toplevel,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  numstat_job = Job:new({
    command = state.adapter:bin(),
    args = utils.vec_join(
      state.adapter:args(),
      "log",
      rev_range,
      "--pretty=format:%x00",
      "--date=raw",
      "--numstat",
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = state.adapter.ctx.toplevel,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  namestat_job:start()
  numstat_job:start()

  latch:await()

  local debug_opt = {
    context = "GitAdapter>incremental_fh_data()",
    func = "s_info",
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

---@param state GitAdapter.FHState
---@param callback fun(status: JobStatus, data?: table, msg?: string[])
local incremental_line_trace_data = async.void(function(state, callback)
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

  local rev_range = state.prepared_log_opts.rev_range

  trace_job = Job:new({
    command = state.adapter:bin(),
    args = utils.vec_join(
      state.adapter:args(),
      "-P",
      "log",
      rev_range,
      "--color=never",
      "--no-ext-diff",
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n  %D%n  %s",
      "--date=raw",
      state.prepared_log_opts.flags,
      "--"
    ),
    cwd = state.adapter.ctx.toplevel,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  trace_job:start()

  latch:await()

  utils.handle_job(trace_job, {
    debug_opt = {
      context = "GitAdapter>incremental_line_trace_data()",
      func = "s_info",
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


---@param path_args string[]
---@param lflags string[]
---@return boolean
function GitAdapter:is_single_file(path_args, lflags)
  if lflags and #lflags > 0 then
    local seen = {}
    for i, v in ipairs(lflags) do
      local path = v:match(".*:(.*)")
      if i > 1 and not seen[path] then
        return false
      end
      seen[path] = true
    end

  elseif path_args and self.ctx.toplevel then
    return #path_args == 1
        and not utils.path:is_dir(path_args[1])
        and #self:exec_sync({ "ls-files", "--", path_args }, self.ctx.toplevel) < 2
  end

  return true
end

---@param log_opt GitLogOptions
---@return boolean ok, string description
function GitAdapter:file_history_dry_run(log_opt)
  local single_file = self:is_single_file(log_opt.path_args, log_opt.L)
  local log_options = config.get_log_options(single_file, log_opt, "git") --[[@as GitLogOptions ]]

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, prepare_fh_options(self, log_options, single_file).flags) --[[@as vector ]]

  local description = utils.vec_join(
    ("Top-level path: '%s'"):format(utils.path:vim_fnamemodify(self.ctx.toplevel, ":~")),
    log_options.rev_range and ("Revision range: '%s'"):format(log_options.rev_range) or nil,
    ("Flags: %s"):format(table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options) --[[@as GitLogOptions ]]
  log_options.max_count = 1
  options = prepare_fh_options(self, log_options, single_file).flags

  local context = "GitAdapter.file_history_dry_run()"
  local cmd

  if #log_options.L > 0 then
    -- cmd = utils.vec_join("-P", "log", log_options.rev_range, "--no-ext-diff", "--color=never", "--pretty=format:%H", "-s", options, "--")
    -- NOTE: Running the dry-run for line tracing is slow. Just skip for now.
    return true, table.concat(description, ", ")
  else
    cmd = utils.vec_join("log", log_options.rev_range, "--pretty=format:%H", "--name-status", options, "--", log_options.path_args)
  end

  local out, code = self:exec_sync(cmd, {
    cwd = self.ctx.toplevel,
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

function GitAdapter:file_history_options(range, paths, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local rel_paths

  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  logger.lvl(1).s_debug(("Found git top-level: %s"):format(utils.str_quote(self.ctx.toplevel)))

  rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths)

  ---@type string
  local range_arg = argo:get_flag("range", { no_empty = true })
  if range_arg then
    local ok = self:verify_rev_arg(range_arg)
    if not ok then
      utils.err(("Bad revision: %s"):format(utils.str_quote(range_arg)))
      return
    end

    logger.lvl(1).s_debug(("Verified range rev: %s"):format(range_arg))
  end

  local log_flag_names = {
    { "follow" },
    { "first-parent" },
    { "show-pulls" },
    { "reflog" },
    { "all" },
    { "merges" },
    { "no-merges" },
    { "reverse" },
    { "max-count", "n" },
    { "L" },
    { "diff-merges" },
    { "author" },
    { "grep" },
    { "base" },
    { "G" },
    { "S" },
  }

  local log_options = { rev_range = range_arg } --[[@as GitLogOptions ]]
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[self.config_key][key]) ~= "boolean",
      expect_list = names[1] == "L",
    })
    log_options[key] = v
  end

  if range then
    paths, rel_paths = {}, {}
    log_options.L = {
      ("%d,%d:%s"):format(range[1], range[2], pl:relative(pl:absolute(cfile), self.ctx.toplevel))
    }
  end

  if log_options.L and next(log_options.L) then
    log_options.follow = false -- '--follow' is not compatible with '-L'
  end

  log_options.path_args = paths

  local ok, opt_description = self:file_history_dry_run(log_options)

  if not ok then
    utils.info({
      ("No git history for the target(s) given the current options! Targets: %s")
        :format(#rel_paths == 0 and "':(top)'" or table.concat(vim.tbl_map(function(v)
          return "'" .. v .. "'"
        end, rel_paths) --[[@as vector ]], ", ")),
      ("Current options: [ %s ]"):format(opt_description)
    })
    return
  end

  if not self.ctx.dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(self.ctx.toplevel))
    )
    return
  end

  return log_options
end

---@param state GitAdapter.FHState
---@return boolean ok
local function parse_fh_line_trace_data(state)
  local cur = state.cur

  local files = {}

  for _, line in ipairs(cur.namestat) do
    if line:match("^diff %-%-git ") then
      local a_path = line:match('^diff %-%-git "?a/(.-)"? "?b/')
      local b_path = line:match('.*"? "?b/(.-)"?$')
      local oldpath = a_path ~= b_path and a_path or nil

      if state.single_file and oldpath then
        state.old_path = oldpath
      end

      table.insert(files, FileEntry.with_layout(state.opt.default_layout or Diff2Hor, {
        adapter = state.adapter,
        path = b_path,
        oldpath = oldpath,
        kind = "working",
        commit = state.commit,
        revs = {
          a = cur.left_hash and GitRev(RevType.COMMIT, cur.left_hash) or GitRev.new_null_tree(),
          b = state.prepared_log_opts.base or GitRev(RevType.COMMIT, cur.right_hash),
        },
      }))
    end
  end

  if files[1] then
    table.insert(
      state.entries,
      LogEntry({
        path_args = state.path_args,
        commit = state.commit,
        files = files,
        single_file = state.single_file,
      })
    )

    state.callback(state.entries, JobStatus.PROGRESS)
  end

  return true
end


---@class GitAdapter.FHState
---@field thread thread
---@field adapter GitAdapter
---@field path_args string[]
---@field log_options GitLogOptions
---@field prepared_log_opts GitAdapter.PreparedLogOpts
---@field opt vcs.adapter.FileHistoryWorkerSpec
---@field single_file boolean
---@field resume_lock boolean
---@field cur table
---@field commit Commit
---@field entries LogEntry[]
---@field callback function

---@param state GitAdapter.FHState
---@return boolean ok, JobStatus? status
local function parse_fh_data(state)
  local cur = state.cur

  -- 'git log --name-status' doesn't work properly for merge commits. It
  -- lists only an incomplete list of files at best. We need to use 'git
  -- show' to get file statuses for merge commits. And merges do not always
  -- have changes.
  if cur.merge_hash and cur.numstat[1] and #cur.numstat ~= #cur.namestat then
    local job
    local job_spec = {
      command = state.adapter:bin(),
      args = utils.vec_join(
        state.adapter:args(),
        "show",
        "--format=",
        "--diff-merges=first-parent",
        "--name-status",
        (state.single_file and state.log_options.follow) and "--follow" or nil,
        cur.right_hash,
        "--",
        state.old_path or state.path_args
      ),
      cwd = state.adapter.ctx.toplevel,
      on_exit = function(j)
        if j.code == 0 then
          cur.namestat = j:result()
        end
        state.adapter:handle_co(state.thread, coroutine.resume(state.thread))
      end,
    }

    local max_retries = 2
    local context = "GitAdapter.file_history_worker()"
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
      state.callback({}, JobStatus.ERROR, job:stderr_result())
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
      if state.single_file then
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

    table.insert(files, FileEntry.with_layout(state.opt.default_layout or Diff2Hor, {
      adapter = state.adapter,
      path = name,
      oldpath = oldname,
      status = status,
      stats = stats,
      kind = "working",
      commit = state.commit,
      revs = {
        a = cur.left_hash and GitRev(RevType.COMMIT, cur.left_hash) or GitRev.new_null_tree(),
        b = state.prepared_log_opts.base or GitRev(RevType.COMMIT, cur.right_hash),
      },
    }))
  end

  if files[1] then
    table.insert(
      state.entries,
      LogEntry({
        path_args = state.path_args,
        commit = state.commit,
        files = files,
        single_file = state.single_file,
      })
    )

    state.callback(state.entries, JobStatus.PROGRESS)
  end

  return true
end



---@param thread thread
---@param log_opt ConfigLogOptions
---@param opt vcs.adapter.FileHistoryWorkerSpec
---@param co_state table
---@param callback function
function GitAdapter:file_history_worker(thread, log_opt, opt, co_state, callback)
  ---@type LogEntry[]
  local entries = {}
  local data = {}
  local data_idx = 1
  local last_status
  local err_msg

  local single_file = self:is_single_file(log_opt.single_file.path_args, log_opt.single_file.L)

  ---@type GitLogOptions
  local log_options = config.get_log_options(
    single_file,
    single_file and log_opt.single_file or log_opt.multi_file,
    "git"
  )

  local is_trace = #log_options.L > 0

  ---@type GitAdapter.FHState
  local state = {
    thread = thread,
    adapter = self,
    path_args = log_opt.single_file.path_args,
    log_options = log_options,
    prepared_log_opts = prepare_fh_options(self, log_options, single_file),
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
      self:handle_co(thread, coroutine.resume(thread))
    end

    if co_state.shutdown then
      return true
    end
  end

  if is_trace then
    incremental_line_trace_data(state, data_callback)
  else
    incremental_fh_data(state, data_callback)
  end

  while true do
    if not vim.tbl_contains({ JobStatus.SUCCESS, JobStatus.ERROR, JobStatus.KILLED }, last_status)
        and not data[data_idx] then
      coroutine.yield()
    end

    if last_status == JobStatus.KILLED then
      logger.warn("File history processing was killed.")
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
      ref_names = state.cur.ref_names,
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


function GitAdapter:diffview_options(args)
  local default_args = config.get_config().default_args.DiffviewOpen
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local rev_arg = argo.args[1]

  local left, right = self:parse_revs(rev_arg, {
    cached = argo:get_flag({ "cached", "staged" }),
    imply_local = argo:get_flag("imply-local"),
  })

  if not (left and right) then
    return
  end

  logger.lvl(1).s_debug(("Parsed revs: left = %s, right = %s"):format(left, right))

  ---@type DiffViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag({ "u", "untracked-files" }, { plain = true }),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
    selected_file = argo:get_flag("selected-file", { no_empty = true, expand = true })
      or (vim.bo.buftype == "" and pl:vim_expand("%:p"))
      or nil,
  }

  return {left = left, right = right, options = options}
end

---@return Rev?
function GitAdapter:head_rev()
  local out, code = self:exec_sync(
    { "rev-parse", "HEAD", "--" },
    { cwd = self.ctx.toplevel, retry_on_empty = 2 }
  )

  if code ~= 0 then
    return
  end

  local s = vim.trim(out[1]):gsub("^%^", "")

  return GitRev(RevType.COMMIT, s, true)
end

---@param path string
---@param rev_arg string?
---@return string?
function GitAdapter:file_blob_hash(path, rev_arg)
  local out, code = self:exec_sync({
    "rev-parse",
    "--revs-only",
    ("%s:%s"):format(rev_arg or "", path)
  }, {
    cwd = self.ctx.toplevel,
    retry_on_empty = 2,
  })

  if code ~= 0 then return end

  return vim.trim(out[1])
end

---Parse two endpoint, commit revs from a symmetric difference notated rev arg.
---@param rev_arg string
---@return Rev? left The left rev.
---@return Rev? right The right rev.
function GitAdapter:symmetric_diff_revs(rev_arg)
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

  out, code, stderr = self:exec_sync({ "merge-base", r1, r2 }, self.ctx.toplevel)
  if code ~= 0 then
    return err()
  end
  local left_hash = out[1]:gsub("^%^", "")

  out, code, stderr = self:exec_sync({ "rev-parse", "--revs-only", r2 }, self.ctx.toplevel)
  if code ~= 0 then
    return err()
  end
  local right_hash = out[1]:gsub("^%^", "")

  return GitRev(RevType.COMMIT, left_hash), GitRev(RevType.COMMIT, right_hash)
end

---Determine whether a rev arg is a range.
---@param rev_arg string
---@return boolean
function GitAdapter:is_rev_arg_range(rev_arg)
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

---Parse a given rev arg.
---@param rev_arg string
---@param opt table
---@return Rev? left
---@return Rev? right
function GitAdapter:parse_revs(rev_arg, opt)
  ---@type Rev?
  local left
  ---@type Rev?
  local right

  local head = self:head_rev()
  ---@cast head Rev

  if not rev_arg then
    if opt.cached then
      left = head or GitRev.new_null_tree()
      right = GitRev(RevType.STAGE, 0)
    else
      left = GitRev(RevType.STAGE, 0)
      right = GitRev(RevType.LOCAL)
    end
  elseif rev_arg:match("%.%.%.") then
    left, right = self:symmetric_diff_revs(rev_arg)
    if not (left or right) then
      return
    elseif opt.imply_local then
      ---@cast left Rev
      ---@cast right Rev
      left, right = self:imply_local(left, right, head)
    end
  else
    local rev_strings, code, stderr = self:exec_sync(
      { "rev-parse", "--revs-only", rev_arg }, self.ctx.toplevel
    )
    if code ~= 0 then
      utils.err(utils.vec_join(
        ("Failed to parse rev %s!"):format(utils.str_quote(rev_arg)),
        "Git output: ",
        stderr
      ))
      return
    elseif #rev_strings == 0 then
      utils.err("Bad revision: " .. utils.str_quote(rev_arg))
      return
    end

    local is_range = self:is_rev_arg_range(rev_arg)

    if is_range then
      local right_hash = rev_strings[1]:gsub("^%^", "")
      right = GitRev(RevType.COMMIT, right_hash)
      if #rev_strings > 1 then
        local left_hash = rev_strings[2]:gsub("^%^", "")
        left = GitRev(RevType.COMMIT, left_hash)
      else
        left = GitRev.new_null_tree()
      end

      if opt.imply_local then
        left, right = self:imply_local(left, right, head)
      end
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      left = GitRev(RevType.COMMIT, hash)
      if opt.cached then
        right = GitRev(RevType.STAGE, 0)
      else
        right = GitRev(RevType.LOCAL)
      end
    end
  end

  return left, right
end

---@param left Rev
---@param right Rev
---@param head Rev
---@return Rev, Rev
function GitAdapter:imply_local(left, right, head)
  if left.commit == head.commit then
    left = GitRev(RevType.LOCAL)
  end
  if right.commit == head.commit then
    right = GitRev(RevType.LOCAL)
  end
  return left, right
end

---Convert revs to git rev args.
---@param left Rev
---@param right Rev
---@return string[]
function GitAdapter:rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { left.commit .. ".." .. right.commit }
  elseif left.type == RevType.STAGE and right.type == RevType.LOCAL then
    return {}
  elseif left.type == RevType.COMMIT and right.type == RevType.STAGE then
    return { "--cached", left.commit }
  else
    return { left.commit }
  end
end


---@param path string
---@param kind vcs.FileKind
---@param commit string?
function GitAdapter:file_restore(path, kind, commit)
  local out, code
  local abs_path = utils.path:join(self.ctx.toplevel, path)
  local rel_path = utils.path:vim_fnamemodify(abs_path, ":~")

  -- Check if file exists in history
  _, code = self:exec_sync(
    { "cat-file", "-e", ("%s:%s"):format(kind == "staged" and "HEAD" or "", path) },
    self.ctx.toplevel
  )
  local exists_git = code == 0
  local exists_local = utils.path:readable(abs_path)

  if exists_local then
    -- Wite file blob into db
    out, code = self:exec_sync({ "hash-object", "-w", "--", path }, self.ctx.toplevel)
    if code ~= 0 then
      utils.err("Failed to write file blob into the object database. Aborting file restoration.", true)
      return false
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
        return false
      end
    end

    if kind == "working" or kind == "conflicting" then
      -- File is untracked and has no history: delete it from fs.
      local ok, err = utils.path:unlink(abs_path)
      if not ok then
        utils.err({
          ("Failed to delete file '%s'! Aborting file restoration. Error message:")
            :format(abs_path),
          err
        }, true)
        return false
      end
    else
      -- File only exists in index
      out, code = self:exec_sync(
        { "rm", "-f", "--", path },
        self.ctx.toplevel
      )
    end
  else
    -- File exists in history: checkout
    out, code = self:exec_sync(
      utils.vec_join("checkout", commit or (kind == "staged" and "HEAD" or nil), "--", path),
      self.ctx.toplevel
    )
  end

  return true, undo
end

---@param file vcs.File
function GitAdapter:stage_index_file(file)
  local out, code, err
  local temp = vim.fn.tempname()

  local ok, ret = pcall(function()
    api.nvim_exec_autocmds("BufWritePre", {
      pattern = api.nvim_buf_get_name(file.bufnr),
    })

    vim.cmd("silent noautocmd keepalt '[,']write " .. temp)

    out, code = self:exec_sync(
      { "--literal-pathspecs", "hash-object", "-w", "--", pl:convert(temp) },
      self.ctx.toplevel
    )

    if code ~= 0 then
      utils.err("Failed to write file blob into the object database. Aborting.")
      return false
    end

    local blob_hash = out[1]

    out, code = self:exec_sync({ "ls-files", "--stage", file.path }, self.ctx.toplevel)
    local old_mode = out[1]:match("^(%d+)")

    if not old_mode then
      old_mode = vim.fn.executable(file.absolute_path) and "100755" or "100644"
    end

    out, code, err = self:exec_sync({ "update-index", "--index-info" }, {
      cwd = self.ctx.toplevel,
      writer = ("%s %s %d\t%s"):format(old_mode, blob_hash, file.rev.stage, file.path),
    })

    if code ~= 0 then
      utils.err(utils.vec_join("Failed to update index!", err))
      return false
    end

    file.blob_hash = blob_hash
    vim.bo[file.bufnr].modified = false
    api.nvim_exec_autocmds("BufWritePost", {
      pattern = api.nvim_buf_get_name(file.bufnr),
    })
  end)

  vim.fn.delete(temp)
  if not ok then error(ret) end

  return ret
end

function GitAdapter:reset_files(paths)
  local _, code = self:exec_sync(utils.vec_join("reset", "--", paths), self.ctx.toplevel)
  return code == 0
end

function GitAdapter:add_files(paths)
  local _, code = self:exec_sync(utils.vec_join("add", "--", paths), self.ctx.toplevel)
  return code == 0
end

---Check if status for untracked files is disabled for a given git repo.
---@return boolean
function GitAdapter:show_untracked()
  local out = self:exec_sync(
    { "config", "status.showUntrackedFiles" },
    { cwd = self.ctx.toplevel, silent = true }
  )
  return vim.trim(out[1] or "") ~= "no"
end

GitAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  ---@type FileEntry[]
  local files = {}
  ---@type FileEntry[]
  local conflicts = {}
  ---@type CountDownLatch
  local latch = CountDownLatch(2)
  local debug_opt = {
    context = "GitAdapter>tracked_files()",
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
    command = self:bin(),
    args = utils.vec_join(self:args(), "diff", "--ignore-submodules", "--name-status", args),
    cwd = self.ctx.toplevel,
    on_exit = on_exit,
  })
  local numstat_job = Job:new({
    command = self:bin(),
    args = utils.vec_join(self:args(), "diff", "--ignore-submodules", "--numstat", args),
    cwd = self.ctx.toplevel,
    on_exit = on_exit,
  })

  namestat_job:start()
  numstat_job:start()
  latch:await()
  local out_status
  if not (#namestat_job:result() == #numstat_job:result()) then
    out_status = vcs_utils.ensure_output(2, { namestat_job, numstat_job }, "GitAdapter>tracked_files()")
  end

  if out_status == JobStatus.ERROR or not (namestat_job.code == 0 and numstat_job.code == 0) then
    callback(utils.vec_join(namestat_job:stderr_result(), numstat_job:stderr_result()), nil)
    return
  end

  local numstat_out = numstat_job:result()
  local namestat_out = namestat_job:result()

  local data = {}
  local conflict_map = {}

  for i, s in ipairs(namestat_out) do
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
        adapter = self,
        path = v.name,
        oldpath = v.oldname,
        status = "U",
        kind = "conflicting",
        revs = {
          a = self.Rev(RevType.STAGE, 2),  -- ours
          b = self.Rev(RevType.LOCAL),     -- local
          c = self.Rev(RevType.STAGE, 3),  -- theirs
          d = self.Rev(RevType.STAGE, 1),  -- base
        },
      }))
    end
  end

  for _, v in ipairs(data) do
    table.insert(files, FileEntry.with_layout(opt.default_layout, {
      adapter = self,
      path = v.name,
      oldpath = v.oldname,
      status = v.status,
      stats = v.stats,
      kind = kind,
      revs = {
        a = left,
        b = right,
      }
    }))
  end

  callback(nil, files, conflicts)
end, 7)

GitAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  Job:new({
    command = self:bin(),
    args = utils.vec_join(self:args(), "ls-files", "--others", "--exclude-standard"),
    cwd = self.ctx.toplevel,
    ---@type Job
    on_exit = function(j)
      utils.handle_job(j, {
        debug_opt = {
          context = "GitAdapter>untracked_files()",
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
        table.insert(files, FileEntry.with_layout(opt.default_layout, {
          adapter = self,
          path = s,
          status = "?",
          kind = "working",
          revs = {
            a = left,
            b = right,
          }
        }))
      end
      callback(nil, files)
    end
  }):start()
end, 5)

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function GitAdapter:rev_to_pretty_string(left, right)
  if left.track_head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function GitAdapter:has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---Strange trick to check if a file is binary using only git.
---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function GitAdapter:is_binary(path, rev)
  if rev.type == RevType.STAGE and rev.stage > 0 then
    return false
  end

  local cmd = { "-c", "submodule.recurse=false", "grep", "-I", "--name-only", "-e", "." }
  if rev.type == RevType.LOCAL then
    cmd[#cmd+1] = "--untracked"
  elseif rev.type == RevType.STAGE then
    cmd[#cmd+1] = "--cached"
  else
    cmd[#cmd+1] = rev.commit
  end

  utils.vec_push(cmd, "--", path)

  local _, code = self:exec_sync(cmd, { cwd = self.ctx.toplevel, silent = true })
  return code ~= 0
end

GitAdapter.flags = {
  ---@type FlagOption[]
  switches = {
    { "-f", "--follow", "Follow renames (only for single file)" },
    { "-p", "--first-parent", "Follow only the first parent upon seeing a merge commit" },
    { "-s", "--show-pulls", "Show merge commits the first introduced a change to a branch" },
    { "-R", "--reflog", "Include all reachable objects mentioned by reflogs" },
    { "-a", "--all", "Include all refs" },
    { "-m", "--merges", "List only merge commits" },
    { "-n", "--no-merges", "List no merge commits" },
    { "-r", "--reverse", "List commits in reverse order" },
  },
  ---@type FlagOption[]
  options = {
    {
      "=r", "++rev-range=", "Show only commits in the specified revision range",
      ---@param panel FHOptionPanel
      completion = function(panel)
        return function(arg_lead, _, _)
          local view = panel.parent.parent
          return view.adapter:rev_completion(arg_lead, {
            accept_range = true,
          })
        end
      end,
    },
    {
      "=b", "++base=", "Set the base revision",
      ---@param panel FHOptionPanel
      completion = function(panel)
        return function(arg_lead, _, _)
          local view = panel.parent.parent
          return utils.vec_join("LOCAL", view.adapter:rev_completion(arg_lead, {}))
        end
      end,
    },
    { "=n", "--max-count=", "Limit the number of commits" },
    {
      "=L", "-L", "Trace line evolution",
      prompt_label = "(Accepts multiple values)",
      prompt_fmt = "${label} ",
      completion = function(_)
        return function(arg_lead, _, _)
          return M.line_trace_completion(arg_lead)
        end
      end,
      transform = function(values)
        return utils.tbl_fmap(values, function(v)
          v = utils.str_match(v, { "^-L(.*)", ".*" })
          if v == "" then return nil end
          return v
        end)
      end,
      ---@param self FlagOption
      ---@param value string|string[]
      render_value = function(self, value)
        if #value == 0 then
          -- Just render the flag name
          return true, self[2]
        end

        -- Render a string of quoted args
        return false, table.concat(vim.tbl_map(function(v)
          if not v:match("^-L") then
            -- Prepend the flag if it wasn't specified by the user.
            v = "-L" .. v
          end
          return utils.str_quote(v, { only_if_whitespace = true })
        end, value), " ")
      end,
      render_default = function(_, value)
        if #value == 0 then
          -- Just render the flag name
          return "-L"
        end

        -- Render a string of quoted args
        return table.concat(vim.tbl_map(function(v)
          v = select(1, v:gsub("\\", "\\\\"))
          return utils.str_quote("-L" .. v, { only_if_whitespace = true })
        end, value), " ")
      end,
    },
    {
      "=d", "--diff-merges=", "Determines how merge commits are treated",
      select = {
        "",
        "off",
        "on",
        "first-parent",
        "separate",
        "combined",
        "dense-combined",
        "remerge",
      },
    },
    { "=a", "--author=", "List only commits from a given author", prompt_label = "(Extended regular expression)" },
    { "=g", "--grep=", "Filter commit messages", prompt_label = "(Extended regular expression)" },
    { "=G", "-G", "Search changes", prompt_label = "(Extended regular expression)" },
    { "=S", "-S", "Search occurrences", prompt_label = "(Extended regular expression)" },
    {
      "--", "--", "Limit to files",
      key = "path_args",
      prompt_label = "(Path arguments)",
      prompt_fmt = "${label}${flag_name} ",
      transform = function(values)
        return utils.tbl_fmap(values, function(v)
          if v == "" then return nil end
          return v
        end)
      end,
      render_value = function(_, value)
        if #value == 0 then
          -- Just render the flag name
          return true, "--"
        end

        -- Render a string of quoted args
        return false, table.concat(utils.vec_join(
          "--",
          vim.tbl_map(function(v)
            v = v:gsub("\\", "\\\\")
            return utils.str_quote(v, { only_if_whitespace = true })
          end, value)
        ), " ")
      end,
      ---@param panel FHOptionPanel
      completion = function(panel)
        local view = panel.parent.parent

        return function(_, cmd_line, cur_pos)
          local ok, ctx = pcall(arg_parser.scan_sh_args, cmd_line, cur_pos)

          if ok then
            local quoted = vim.tbl_map(function(v)
              return utils.str_quote(v, { only_if_whitespace = true })
            end, ctx.args)

            return vim.tbl_map(function(v)
              return table.concat(utils.vec_join(
                utils.vec_slice(quoted, 1, ctx.argidx - 1),
                utils.str_quote(v, { only_if_whitespace = true })
              ), " ")
            end, view.adapter:path_completion(ctx.arg_lead))
          end
        end
      end,
    },
  },
}

for _, list in pairs(GitAdapter.flags) do
  for i, option in ipairs(list) do
    option = vim.tbl_extend("keep", option, {
      prompt_fmt = "${label}${flag_name}",

      key = option.key or utils.str_match(option[2], {
        "^%-%-?([^=]+)=?",
        "^%+%+?([^=]+)=?",
      }):gsub("%-", "_"),

      ---@param self FlagOption
      ---@param value string|string[]
      render_value = function(self, value)
        local quoted

        if type(value) == "table" then
          quoted = table.concat(vim.tbl_map(function(v)
            return self[2] .. utils.str_quote(v, { only_if_whitespace = true })
          end, value), " ")
        else
          quoted = self[2] .. utils.str_quote(value, { only_if_whitespace = true })
        end

        return value == "", quoted
      end,

      ---@param value string|string[]
      render_default = function(_, value)
        if value == nil then
          return ""
        elseif type(value) == "table" then
          return table.concat(vim.tbl_map(function(v)
            v = select(1, v:gsub("\\", "\\\\"))
            return utils.str_quote(v, { only_if_whitespace = true })
          end, value), " ")
        end
        return utils.str_quote(value, { only_if_whitespace = true })
      end,
    })

    list[i] = option
    list[option.key] = option
  end
end

-- Completion

function GitAdapter:path_completion(arg_lead)
  local magic, pattern = M.pathspec_split(arg_lead)

  return vim.tbl_map(function(v)
    return magic .. v
  end, vim.fn.getcompletion(pattern, "file", 0))
end

function GitAdapter:rev_candidates()
  logger.lvl(1).debug("[completion] Revision candidates requested.")
  -- stylua: ignore start
  local targets = {
    "HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
    "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"
  }
  -- stylua: ignore end

  local heads = vim.tbl_filter(
    function(name) return vim.tbl_contains(targets, name) end,
    vim.tbl_map(
      function(v) return utils.path:basename(v) end,
      vim.fn.glob(self.ctx.dir .. "/*", false, true)
    )
  )
  local revs = self:exec_sync(
    { "rev-parse", "--symbolic", "--branches", "--tags", "--remotes" },
    { cwd = self.ctx.toplevel, silent = true }
  )
  local stashes = self:exec_sync(
    { "stash", "list", "--pretty=format:%gd" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  return utils.vec_join(heads, revs, stashes)
end

---Completion for git revisions.
---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function GitAdapter:rev_completion(arg_lead, opt)
  ---@type RevCompletionSpec
  opt = vim.tbl_extend("keep", opt or {}, { accept_range = false })
  local candidates = self:rev_candidates()
  local _, range_end = utils.str_match(arg_lead, {
    "^(%.%.%.?)()$",
    "^(%.%.%.?)()[^.]",
    "[^.](%.%.%.?)()$",
    "[^.](%.%.%.?)()[^.]",
  })

  if opt.accept_range and range_end then
    local range_lead = arg_lead:sub(1, range_end - 1)
    candidates = vim.tbl_map(function(v)
      return range_lead .. v
    end, candidates)
  end

  return diffview.filter_completion(arg_lead, candidates)
end

---Completion for the git-log `-L` flag.
---@param arg_lead string
---@return string[]?
function M.line_trace_completion(arg_lead)
  local range_end = arg_lead:match(".*:()")

  if not range_end then
    return
  else
    local lead = arg_lead:sub(1, range_end - 1)
    local path_lead = arg_lead:sub(range_end)

    return vim.tbl_map(function(v)
      return lead .. v
    end, vim.fn.getcompletion(path_lead, "file"))
  end
end


function GitAdapter:init_completion()
  self.comp.open:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
  self.comp.open:put({ "cached", "staged" })
  self.comp.open:put({ "imply-local" })
  self.comp.open:put({ "C" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.open:put({ "selected-file" }, function (_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "file")
  end)

  self.comp.file_history:put({ "base" }, function(_, arg_lead)
    return utils.vec_join("LOCAL", self:rev_completion(arg_lead))
  end)
  self.comp.file_history:put({ "range" }, function(_, arg_lead)
    return self:rev_completion(arg_lead, { accept_range = true })
  end)
  self.comp.file_history:put({ "C" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.file_history:put({ "--follow" })
  self.comp.file_history:put({ "--first-parent" })
  self.comp.file_history:put({ "--show-pulls" })
  self.comp.file_history:put({ "--reflog" })
  self.comp.file_history:put({ "--all" })
  self.comp.file_history:put({ "--merges" })
  self.comp.file_history:put({ "--no-merges" })
  self.comp.file_history:put({ "--reverse" })
  self.comp.file_history:put({ "--max-count", "-n" }, {})
  self.comp.file_history:put({ "-L" }, function (_, arg_lead)
    return M.line_trace_completion(arg_lead)
  end)
  self.comp.file_history:put({ "--diff-merges" }, {
    "off",
    "on",
    "first-parent",
    "separate",
    "combined",
    "dense-combined",
    "remerge",
  })
  self.comp.file_history:put({ "--author" }, {})
  self.comp.file_history:put({ "--grep" }, {})
  self.comp.file_history:put({ "-G" }, {})
  self.comp.file_history:put({ "-S" }, {})
end

M.GitAdapter = GitAdapter
return M
