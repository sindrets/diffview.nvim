local oop = require('diffview.oop')
local arg_parser = require('diffview.arg_parser')
local logger = require('diffview.logger')
local utils = require('diffview.utils')
local async = require("plenary.async")
local config = require('diffview.config')
local lazy = require('diffview.lazy')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

---@type PathLib
local pl = lazy.access(utils, "path")

local M = {}

local GitAdapter = oop.create_class('GitAdapter', VCSAdapter)

function GitAdapter:init(path)
  self.super:init(path)

  self.bootstrap.version_string = nil
  self.bootstrap.version = {}
  self.bootstrap.target_version_string = nil
  self.bootstrap.target_version = {
    major = 2,
    minor = 31,
    patch = 0,
  }

  self.context = self:get_context(path)
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

function GitAdapter:get_context(path)
  local context = {}
  local out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--show-toplevel" }, path)
  if code ~= 0 then
    return nil
  end
  context.toplevel = out[1] and vim.trim(out[1])

  out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--git-dir" }, path)
  if code ~= 0 then
    return nil
  end
  context.dir = out[1] and vim.trim(out[1])
  return context
end

---@return string, string
local function pathspec_split(pathspec)
  local magic = pathspec:match("^:[/!^]*:?") or pathspec:match("^:%b()") or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic or "", pattern or ""
end

local function pathspec_expand(toplevel, cwd, pathspec)
  local magic, pattern = pathspec_split(pathspec)
  if not utils.path:is_abs(pattern) then
    pattern = utils.path:join(utils.path:relative(cwd, toplevel), pattern)
  end
  return magic .. utils.path:convert(pattern)
end

local function pathspec_modify(pathspec, mods)
  local magic, pattern = pathspec_split(pathspec)
  return magic .. utils.path:vim_fnamemodify(pattern, mods)
end

function GitAdapter:find_git_toplevel(top_indicators)
  local toplevel
  for _, p in ipairs(top_indicators) do
    if not pl:is_dir(p) then
      p = pl:parent(p)
    end

    if p and pl:readable(p) then
      local ctxt = self:get_context(p)
      toplevel = ctxt.toplevel

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
  )

end

---@class git.utils.PreparedLogOpts
---@field rev_range string
---@field base Rev
---@field path_args string[]
---@field flags string[]

---@param toplevel string
---@param log_options LogOptions
---@param single_file boolean
---@return git.utils.PreparedLogOpts
local function prepare_fh_options(toplevel, log_options, single_file)
  local o = log_options
  local line_trace = vim.tbl_map(function(v)
    if not v:match("^-L") then
      return "-L" .. v
    end
    return v
  end, o.L or {})

  local rev_range, base

  if log_options.rev_range then
    local ok, _ = M.verify_rev_arg(toplevel, log_options.rev_range)

    if not ok then
      utils.warn(("Bad range revision, ignoring: %s"):format(utils.str_quote(log_options.rev_range)))
    else
      rev_range = log_options.rev_range
    end
  end

  if log_options.base then
    if log_options.base == "LOCAL" then
      base = Rev(RevType.LOCAL)
    else
      local ok, out = M.verify_rev_arg(toplevel, log_options.base)

      if not ok then
        utils.warn(("Bad base revision, ignoring: %s"):format(utils.str_quote(log_options.base)))
      else
        base = Rev(RevType.COMMIT, out[1])
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
      o.grep and { "-E", "--grep=" .. o.grep } or nil
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

---@param state git.utils.FHState
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
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "log",
      rev_range,
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n  %D%n  %s",
      "--date=raw",
      "--name-status",
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = state.ctx.toplevel,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  numstat_job = Job:new({
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
      "log",
      rev_range,
      "--pretty=format:%x00",
      "--date=raw",
      "--numstat",
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = state.ctx.toplevel,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  namestat_job:start()
  numstat_job:start()

  latch:await()

  local debug_opt = {
    context = "git.utils>incremental_fh_data()",
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

---@param state git.utils.FHState
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
    command = git_bin(),
    args = utils.vec_join(
      git_args(),
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
    cwd = state.ctx.toplevel,
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

---@param toplevel string
---@param path_args string[]
---@param lflags string[]
---@return boolean
function GitAdapter:is_single_file(toplevel, path_args, lflags)
  if lflags and #lflags > 0 then
    local seen = {}
    for i, v in ipairs(lflags) do
      local path = v:match(".*:(.*)")
      if i > 1 and not seen[path] then
        return false
      end
      seen[path] = true
    end

  elseif path_args and toplevel then
    return #path_args == 1
        and not utils.path:is_dir(path_args[1])
        and #self:exec_sync({ "ls-files", "--", path_args }, toplevel) < 2
  end

  return true
end

---@param toplevel string
---@param log_opt LogOptions
---@return boolean ok, string description
function GitAdapter:file_history_dry_run(toplevel, log_opt)
  local single_file = self:is_single_file(toplevel, log_opt.path_args, log_opt.L)
  local log_options = config.get_log_options(single_file, log_opt)

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, prepare_fh_options(toplevel, log_options, single_file).flags) --[[@as vector ]]

  local description = utils.vec_join(
    ("Top-level path: '%s'"):format(utils.path:vim_fnamemodify(toplevel, ":~")),
    log_options.rev_range and ("Revision range: '%s'"):format(log_options.rev_range) or nil,
    ("Flags: %s"):format(table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options) --[[@as LogOptions ]]
  log_options.max_count = 1
  options = prepare_fh_options(toplevel, log_options, single_file).flags

  local context = "git.utils.file_history_dry_run()"
  local cmd

  if #log_options.L > 0 then
    -- cmd = utils.vec_join("-P", "log", log_options.rev_range, "--no-ext-diff", "--color=never", "--pretty=format:%H", "-s", options, "--")
    -- NOTE: Running the dry-run for line tracing is slow. Just skip for now.
    return true, table.concat(description, ", ")
  else
    cmd = utils.vec_join("log", log_options.rev_range, "--pretty=format:%H", "--name-status", options, "--", log_options.path_args)
  end

  local out, code = self:exec_sync(cmd, {
    cwd = toplevel,
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

---@param range? { [1]: integer, [2]: integer }
---@param args string[]
function GitAdapter:file_history_options(range, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local paths = {}
  local rel_paths

  logger.info("[command call] :DiffviewFileHistory " .. table.concat(vim.tbl_flatten({
    default_args,
    args,
  }), " "))

  for _, path_arg in ipairs(argo.args) do
    for _, path in ipairs(pl:vim_expand(path_arg, false, true)) do
      local magic, pattern = pathspec_split(path)
      pattern = pl:readlink(pattern) or pattern
      table.insert(paths, magic .. pattern)
    end
  end

  ---@type string
  local cpath = argo:get_flag("C", { no_empty = true, expand = true })
  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  local top_indicators = {}
  for _, path in ipairs(paths) do
    if pathspec_split(path) == "" then
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

  local err, git_toplevel = self:find_git_toplevel(top_indicators)

  if err then
    utils.err(err)
    return
  end

  ---@cast git_toplevel string
  logger.lvl(1).s_debug(("Found git top-level: %s"):format(utils.str_quote(git_toplevel)))

  rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths)

  local cwd = cpath or vim.loop.cwd()
  paths = vim.tbl_map(function(pathspec)
    return pathspec_expand(git_toplevel, cwd, pathspec)
  end, paths) --[[@as string[] ]]

  ---@type string
  local range_arg = argo:get_flag("range", { no_empty = true })
  if range_arg then
    local ok = self:verify_rev_arg(git_toplevel, range_arg)
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
  }

  ---@type LogOptions
  local log_options = { rev_range = range_arg }
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[key]) ~= "boolean",
      expect_list = names[1] == "L",
    })
    log_options[key] = v
  end

  if range then
    paths, rel_paths = {}, {}
    log_options.L = {
      ("%d,%d:%s"):format(range[1], range[2], pl:relative(pl:absolute(cfile), git_toplevel))
    }
  end

  log_options.path_args = paths

  local ok, opt_description = self:file_history_dry_run(git_toplevel, log_options)

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

  local git_ctx = {
    toplevel = git_toplevel,
    dir = self.context.dir,
  }

  if not git_ctx.dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(git_ctx.toplevel))
    )
    return
  end

  return log_options
end

M.GitAdapter = GitAdapter
return M
