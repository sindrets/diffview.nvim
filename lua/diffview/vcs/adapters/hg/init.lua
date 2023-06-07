local Commit = require("diffview.vcs.adapters.hg.commit").HgCommit
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileEntry = require("diffview.scene.file_entry").FileEntry
local FlagOption = require("diffview.vcs.flag_option").FlagOption
local HgRev = require('diffview.vcs.adapters.hg.rev').HgRev
local Job = require("diffview.job").Job
local JobStatus = require('diffview.vcs.utils').JobStatus
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local RevType = require("diffview.vcs.rev").RevType
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter
local arg_parser = require("diffview.arg_parser")
local async = require("diffview.async")
local config = require('diffview.config')
local lazy = require('diffview.lazy')
local oop = require('diffview.oop')
local utils = require('diffview.utils')
local vcs_utils = require("diffview.vcs.utils")

local await, pawait = async.await, async.pawait
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

---@class HgAdapter : VCSAdapter
local HgAdapter = oop.create_class('HgAdapter', VCSAdapter)

HgAdapter.Rev = HgRev
HgAdapter.config_key = "hg"
HgAdapter.bootstrap = {
  done = false,
  ok = false,
  version = {},
  target_version = {
    major = 5,
    minor = 4,
    patch = 0,
  }
}

function HgAdapter.run_bootstrap()
  local hg_cmd = config.get_config().hg_cmd
  local bs = HgAdapter.bootstrap
  bs.done = true

  local function err(msg)
    if msg then
      bs.err = msg
      logger:error("[HgAdapter] " .. bs.err)
    end
  end

  if vim.fn.executable(hg_cmd[1]) ~= 1 then
    return err(fmt("Configured `hg_cmd` is not executable: '%s'", hg_cmd[1]))
  end

  local out = utils.job(vim.tbl_flatten({ hg_cmd, "version" }))
  local version = out[1] and out[1]:match("Mercurial .*%(version (%S*)%)") or nil
  if not version then
    return err("Could not get Mercurial version!")
  end

  -- Parse version string
  local major, minor, patch = version:match("(%d+)%.?(%d*)%.?(%d*)")
  if not major then
    return err(string.format("Could not parse Mercurial version: %s!", version))
  end

  local v, target = bs.version, bs.target_version
  v.major = tonumber(major)
  v.minor = tonumber(minor) or 0
  v.patch = tonumber(patch) or 0

  bs.version_string = version
  bs.target_version_string = fmt("%d.%d.%d", target.major, target.minor, target.patch)

  local version_ok = vcs_utils.check_semver(v, target)
  if not version_ok then
    return err(string.format(
      "Mercurial version is outdated! Some functionality might not work as expected, "
        .. "or not at all! Current: %s, wanted: %s",
      bs.version_string,
      bs.target_version_string
    ))
  end

  bs.ok = true
end

function HgAdapter.get_repo_paths(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  for _, path_arg in ipairs(path_args) do
    for _, path in ipairs(pl:vim_expand(path_arg, false, true) --[[@as string[] ]]) do
      path = pl:readlink(path) or path
      table.insert(paths, path)
    end
  end

  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  for _, path in ipairs(paths) do
    table.insert(top_indicators, pl:absolute(path, cpath))
    break
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
  local out, code = utils.job(vim.tbl_flatten({config.get_config().hg_cmd, {"root"}}), path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

function HgAdapter.find_toplevel(top_indicators)
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

  local msg_paths = vim.tbl_map(function(v)
    local rel_path = pl:relative(v, ".")
    return utils.str_quote(rel_path == "" and "." or rel_path)
  end, top_indicators)

  local err = fmt(
    "Path not a mercurial repo (or any parent): %s",
    table.concat(msg_paths, ", ")
  )

  return err, ""
end

---@param toplevel string
---@param path_args string[]
---@param cpath string?
---@return string? err
---@return HgAdapter
function HgAdapter.create(toplevel, path_args, cpath)
  local err
  local adapter = HgAdapter({
    toplevel = toplevel,
    path_args = path_args,
    cpath = cpath,
  })

  if not adapter.ctx.toplevel then
    err = "Could not file top-level of the repository!"
  elseif not pl:is_dir(adapter.ctx.toplevel) then
    err = "The top-level is not a readable directory: " .. adapter.ctx.toplevel
  end

  return err, adapter
end

function HgAdapter:init(opt)
  opt = opt or {}
  self:super(opt)

  self.ctx = {
    toplevel = opt.toplevel,
    dir = self:get_dir(opt.toplevel),
    path_args = opt.path_args or {},
  }

  self:init_completion()
end

function HgAdapter:get_command()
  return config.get_config().hg_cmd
end

function HgAdapter:get_show_args(path, rev)
  return utils.vec_join(self:args(), "cat", "--rev", rev:object_name(), "--", path)
end

function HgAdapter:get_log_args(args)
  return utils.vec_join("log", "--stat", '--rev', args)
end

function HgAdapter:get_dir(path)
  local out, code = self:exec_sync({ "root", "--template={hgpath}" }, path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

function HgAdapter:get_merge_context()
  local ret = {}

  local out, code = self:exec_sync({ "debugmergestate", "-Tjson" }, self.ctx.toplevel)

  if code ~= 0 then
    return {ours = {}, theirs = {}, base = {}}
  end

  local data = vim.json.decode(table.concat(out, ""))

  ret.base = { hash = "" }

  for _, commit in ipairs(data[1].commits) do
    if commit.name == "other" then
      ret.theirs = { hash = commit.node }
      out, code = self:exec_sync({ "log", "--template={branch}", "--rev", commit.node }, self.ctx.toplevel)
      if code == 0 then
        ret.theirs.ref_names = out[1]
      end
    elseif commit.name == "local" then
      ret.ours = { hash = commit.node }
      out, code = self:exec_sync({ "log", "--template={branch}", "--rev", commit.node }, self.ctx.toplevel)
      if code == 0 then
        ret.ours.ref_names = out[1]
      end
    end
  end

  for _, file in ipairs(data[1].files) do
    for _, extra in ipairs(file.extras) do
      if (extra.key == 'ancestorlinknode' and extra.value ~= HgAdapter.Rev.NULL_TREE_SHA) then
        ret.base.hash = extra.value
        break
      end
    end
  end

  return ret
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
function HgAdapter:file_history_options(range, paths, argo)
  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  local rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths) --[[@as string[] ]]

  local range_arg = argo:get_flag('rev', { no_empty = true })
  -- if range_arg then
  --   -- TODO: check if range is valid
  -- end

  if range then
    utils.err("Line ranges are not supported for hg!")
    return
  end

  local log_flag_names = {
    { "rev", "r" },
    { "follow", "f" },
    { "limit", "l" },
    { "no-merges", "M" },
    { "user", "u" },
    { "keyword", "k" },
    { "branch" },
    { "bookmark" },
    { "include", "I" },
    { "exclude", "X" },
  }

  ---@type HgLogOptions
  local log_options = { rev_range = range_arg }
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[self.config_key][key]) ~= "boolean",
    })
    log_options[key] = v
  end

  log_options.path_args = paths

  local ok, opt_description = self:file_history_dry_run(log_options)

  if not ok then
    local msg = "No git history for the target(s) given the current options! Targets: %s\n"
      .. "Current options: [ %s ]"

    if #rel_paths == 0 then
      utils.info(fmt(msg, "':(top)'", opt_description))
    else
      local msg_paths = vim.tbl_map(utils.str_quote, rel_paths)
      utils.info(fmt(msg, table.concat(msg_paths, ", "), opt_description))
    end

    return
  end

  return log_options
end

---@class HgAdapter.PreparedLogOpts
---@field rev_range string
---@field base Rev
---@field path_args string[]
---@field flags string[]

---@class HgAdapter.FHState
---@field path_args string[]
---@field log_options HgLogOptions
---@field prepared_log_opts HgAdapter.PreparedLogOpts
---@field layout_opt vcs.adapter.LayoutOpt
---@field single_file boolean
---@field old_path string?

---@param log_options HgLogOptions
---@param single_file boolean
---@return HgAdapter.PreparedLogOpts
function HgAdapter:prepare_fh_options(log_options, single_file)
  local o = log_options
  local rev_range, base

  if log_options.rev then
    rev_range = log_options.rev
  end

  -- if log_options.base then
  --   -- TODO
  -- end

  return {
    rev_range = rev_range,
    base = base,
    path_args = log_options.path_args,
    flags = utils.vec_join(
      (o.follow and single_file) and { "--follow" } or nil,
      o.limit and { "--limit=" .. o.limit } or nil,
      o.no_merges and { "--no-merges" } or nil,
      o.user and { "--user=" .. o.user } or nil,
      o.keyword and { "--keyword=" .. o.keyword } or nil,
      o.branch and { "--branch=" .. o.branch } or nil,
      o.bookmark and { "--bookmark=" .. o.bookmark } or nil,
      o.include and { "--include=" .. o.include } or nil,
      o.exclude and { "--exclude=" .. o.exclude } or nil
    ),
  }
end

---@param log_opt HgLogOptions
---@return boolean ok, string description
function HgAdapter:file_history_dry_run(log_opt)
  local single_file = self:is_single_file(log_opt.path_args)
  local log_options = config.get_log_options(single_file, log_opt, self.config_key) --[[@as HgLogOptions ]]

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, self:prepare_fh_options(log_options, single_file).flags) --[[@as vector ]]

  local description = utils.vec_join(
    fmt("Top-level path: '%s'", pl:vim_fnamemodify(self.ctx.toplevel, ":~")),
    log_options.rev and fmt("Revision range: '%s'", log_options.rev) or nil,
    fmt("Flags: %s", table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options) --[[@as HgLogOptions ]]
  log_options.limit = 1
  -- TODO
  options = self:prepare_fh_options(log_options, single_file).flags

  local context = "HgAdapter:file_history_dry_run()"
  local cmd = utils.vec_join(
    "log",
    log_options.rev and "--rev=" .. log_options.rev or nil,
    options,
    log_options.path_args
  )

  local out, code = self:exec_sync(cmd, {
    cwd = self.ctx.toplevel,
    log_opt = { label = context },
  })

  local ok = code == 0 and #out > 0

  if not ok then
    logger:fmt_debug("[%s] Dry run failed.", context)
  end

  return ok, table.concat(description, ", ")
end

local function structure_fh_data(namestat_data, numstat_data)
  local right_hash, left_hash, merge_hash = unpack(utils.str_split(namestat_data[1]))
  local time, time_offset = namestat_data[3]:match('(%d+.%d*)([-+]?%d*)')

  return {
    left_hash = left_hash ~= "" and left_hash or nil,
    right_hash = right_hash,
    merge_hash = merge_hash ~= "" and merge_hash or nil,
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


---@param self HgAdapter
---@param state HgAdapter.FHState
---@param callback fun(status: JobStatus, data?: table, msg?: string)
HgAdapter.incremental_fh_data = async.void(function(self, state, callback)
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

        if not shutdown
          and not raw[handler_state.idx].done
          and raw[handler_state.idx].namestat
          and raw[handler_state.idx].numstat
        then
          raw[handler_state.idx].done = true
          shutdown = callback(
            JobStatus.PROGRESS,
            structure_fh_data(raw[handler_state.idx].namestat, raw[handler_state.idx].numstat)
          )

          if shutdown then
            logger:debug("Killing file history jobs...")
            namestat_job:kill(64)
            numstat_job:kill(64)
          end
        end
      end
      handler_state.idx = handler_state.idx + 1
      handler_state.data = {}
    elseif line ~= "" then
      handler_state.data[#handler_state.data + 1] = line
    end
  end

  local function on_exit(j, ok)
    if ok and j.code == 0 then on_stdout(nil, "\0", j) end
  end

  local rev_range = state.prepared_log_opts.rev_range and '--rev=' .. state.prepared_log_opts.rev_range or nil
  local log_opt = { label = "HgAdapter:incremental_fh_data()" }

  namestat_job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "log",
      rev_range,
      '--template=\\x00\n'
        .. '{node} {p1.node} {ifeq(p2.rev, -1 ,\"\", \"{p2.node}\")}\n'
        .. '{author|person}\n'
        .. '{date}\n'
        .. '{date|age}\n'
        .. '  {separate(", ", tags, topics)}\n'
        .. '  {desc|firstline}\n'
        .. '{files % "{status} {file}\n"}',
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = self.ctx.toplevel,
    log_opt = log_opt,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  numstat_job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "log",
      rev_range,
      "--template=\\x00\n",
      '--stat',
      state.prepared_log_opts.flags,
      "--",
      state.path_args
    ),
    cwd = self.ctx.toplevel,
    log_opt = log_opt,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  local ok = await(Job.join({ namestat_job, numstat_job }))

  if shutdown then
    callback(JobStatus.KILLED)
  elseif not ok then
    callback(
      JobStatus.ERROR,
      nil,
      table.concat(utils.vec_join(namestat_job.stderr, numstat_job.stderr), "\n")
    )
  else
    callback(JobStatus.SUCCESS)
  end
end)

function HgAdapter:is_single_file(path_args, lflags)
  if path_args and self.ctx.toplevel then
    return #path_args == 1
      and not pl:is_dir(path_args[1])
      and #self:exec_sync({ "files", "--", path_args }, self.ctx.toplevel) < 2
  end
  return true
end

---@param self HgAdapter
---@param co_state table
---@param opt vcs.adapter.FileHistoryWorkerSpec
---@param callback (fun(entries: LogEntry[], status: JobStatus, err?: string)) # Called whenever there are new entries available.
HgAdapter.file_history_worker = async.void(function(self, co_state, opt, callback)
  local entries = {} ---@type LogEntry[]

  local single_file = self:is_single_file(
    opt.log_opt.single_file.path_args,
    opt.log_opt.single_file.L
  )

  ---@type HgLogOptions
  local log_options = config.get_log_options(
    single_file,
    single_file and opt.log_opt.single_file or opt.log_opt.multi_file,
    "hg"
  )

  -- TODO: Change in the future if `-L` is implemented
  local is_trace = false

  ---@type HgAdapter.FHState
  local state = {
    co_state = co_state,
    path_args = opt.log_opt.single_file.path_args,
    log_options = log_options,
    prepared_log_opts = self:prepare_fh_options(log_options, single_file),
    layout_opt = opt.layout_opt,
    single_file = single_file,
  }

  local data_buffer = {}
  local data_idx = 0

  ---Wakes the data scheduler
  ---@type function?
  local data_step

  local function inc_callback(status, new_data, msg)
    data_buffer[#data_buffer+1] = { status, new_data, msg }

    if data_step then
      local temp = data_step
      data_step = nil
      temp(status, new_data, msg)
    end

    return co_state.shutdown
  end

  ---Yield until data is available
  ---@param cb (fun(status: JobStatus, new_data: table, err?: string))
  local data_scheduler = async.wrap(function(cb)
    data_idx = data_idx + 1

    if data_buffer[data_idx] then
      cb(unpack(data_buffer[data_idx], 1, 3))
    else
      -- Await new data from inc workers
      data_step = cb
    end
  end)

  if is_trace then
    error("Unimplemented!")
  else
    self:incremental_fh_data(state, inc_callback)
  end

  while true do
    ---@type JobStatus, table?, string?
    local status, new_data, msg = await(data_scheduler())

    if status == JobStatus.KILLED then
      logger:warn("File history processing was killed.")
      callback(entries, status)
      return
    elseif status == JobStatus.ERROR then
      callback(entries, status, msg)
      return
    elseif status == JobStatus.SUCCESS then
      callback(entries, status)
      return
    elseif status ~= JobStatus.PROGRESS then
      error("Unexpected state!")
    end

    -- Status is PROGRESS
    assert(new_data, "No data received from scheduler!")

    -- 'git log --name-status' doesn't work properly for merge commits. It
    -- lists only an incomplete list of files at best. We need to use 'git
    -- show' to get file statuses for merge commits. And merges do not always
    -- have changes.
    if new_data.merge_hash
      and new_data.numstat[1]
      and #new_data.numstat ~= #new_data.namestat
    then
      local job = Job({
        command = self:bin(),
        args = utils.vec_join(
          self:args(),
          "status",
          "--change",
          new_data.right_hash,
          "--",
          state.old_path or state.path_args
        ),
        cwd = self.ctx.toplevel,
        -- Git sometimes fails this job silently (exit code 0). Not sure why,
        -- possibly because we are running multiple git opeartions on the same
        -- repo concurrently. Retrying the job usually solves this.
        retry = 2,
        fail_cond = Job.FAIL_COND.on_empty,
        log_opt = { label = "HgAdapter:file_history_worker()" },
      })

      local ok = await(job)

      if job.code == 0 then
        new_data.namestat = job.stdout
      end

      if not ok or job.code ~= 0 then
        callback(entries, JobStatus.ERROR, table.concat(job.stderr, "\n"))
        return
      end

      if #new_data.namestat == 0 then
        -- Give up: something has been renamed. We can no longer track the
        -- history.
        logger:warn(fmt("[%s] Giving up.", job.log_opt.label))
        utils.warn("Displayed history may be incomplete. Check ':DiffviewLog' for details.", true)
        callback(
          entries,
          JobStatus.ERROR,
          fmt("Failed to get log data for merge commit '%s'!", new_data.right_hash)
        )
        return
      end
    end

    local commit = Commit({
      hash = new_data.right_hash,
      author = new_data.author,
      time = tonumber(new_data.time),
      time_offset = new_data.time_offset,
      rel_date = new_data.rel_date,
      ref_names = new_data.ref_names,
      subject = new_data.subject,
      diff = new_data.diff,
    })

    ---@type boolean, (LogEntry|string)?
    local ok, entry

    if is_trace then
      error("Unimplemented")
    else
      ok, entry = self:parse_fh_data(new_data, commit, state)
    end

    -- Some commits might not have file data. In that case we simply ignore it,
    -- as the fh panel doesn't support such entries at the moment.
    if ok then
      entries[#entries + 1] = entry
      callback(entries, JobStatus.PROGRESS)
    end
  end
end)

---@param data table
---@param commit HgCommit
---@param state HgAdapter.FHState
---@return boolean success
---@return LogEntry|string ret
function HgAdapter:parse_fh_data(data, commit, state)
  local files = {}

  for i = 1, #data.numstat - 1 do
    local status = data.namestat[i]:sub(1, 1):gsub("%s", " ")
    if status == 'R' then
      -- R is for Removed in mercurial
      status = 'D'
    end


    local stats = {}
    local name, changes, diffstats = data.numstat[i]:match("(.*)|%s+(%d+)%s*([+-]*)")
    name = vim.trim(name)

    local oldname
    if name:match('=>') ~= nil then
      oldname, name = name:match('(.*) => (.*)')
      oldname = vim.trim(oldname)
      name = vim.trim(name)
      -- Mark as Renamed
      status = 'R'
    end

    if changes and diffstats then
      local _, adds = diffstats:gsub("+", "")

      stats = {
        additions = tonumber(adds),
        deletions = tonumber(changes) - tonumber(adds),
      }
    end

    if not stats.additions or not stats.deletions then
      stats = nil
    end

    table.insert(
      files,
      FileEntry.with_layout(
        state.layout_opt.default_layout or Diff2Hor,
        {
          adapter = self,
          path = name,
          oldpath = oldname,
          status = status,
          stats = stats,
          kind = "working",
          commit = commit,
          revs = {
            a = data.left_hash and HgRev(RevType.COMMIT, data.left_hash) or HgRev.new_null_tree(),
            b = state.prepared_log_opts.base or HgRev(RevType.COMMIT, data.right_hash),
          }
        }
      )
    )
  end

  if files[1] then
    return true, LogEntry({
      path_args = state.path_args,
      commit = commit,
      files = files,
      single_file = state.single_file,
    })
  end

  logger:debug("[HgAdapter:parse_fh_data] Encountered commit with no file data:", data)

  return false, "Missing file data!"
end

---@param argo ArgObject
function HgAdapter:diffview_options(argo)
  local rev_args = argo.args[1]

  local left, right = self:parse_revs(rev_args, {})
  if not (left and right) then
    return
  end

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

function HgAdapter:rev_to_pretty_string(left, right)
  if left.track_head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif right and right.commit then
    return left:abbrev() .. "::" .. right:abbrev()
  end
  return nil
end

function HgAdapter:head_rev()
  local out, code = self:exec_sync( { "log", "--template={node}", "--limit=1", "--" }, {
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_on_empty = true,
  })

  if code ~= 0 then
    return
  end

  local s = vim.trim(out[1]):gsub("^%^", "")

  return HgRev(RevType.COMMIT, s, true)
end

function HgAdapter:rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "Can't diff LOCAL against LOCAL!"
  )
  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { '--rev=' .. left.commit .. '::' .. right.commit}
  elseif left.type == RevType.STAGE and right.type == RevType.LOCAL then
    return {}
  else
    return { '--rev=' .. left.commit }
  end
end


---Determine whether a rev arg is a range.
---@param rev_arg string
---@return boolean
function HgAdapter:is_rev_arg_range(rev_arg)
  return utils.str_match(rev_arg, {
    "%:",
    "%:%:",
  }) ~= nil
end

---Parse a given rev arg.
---@param rev_arg string
---@param opt table
---@return Rev? left
---@return Rev? right
function HgAdapter:parse_revs(rev_arg, opt)
  ---@type Rev?
  local left
  ---@type Rev?
  local right

  local head = self:head_rev()
  ---@cast head Rev

  if not rev_arg then
    left = head or HgRev.new_null_tree()
    right = HgRev(RevType.LOCAL)
  else
    local from, to = rev_arg:match("([^:]*)%:%:?(.*)$")

    if from and from ~= ""  and to and to ~= "" then
      left = HgRev(RevType.COMMIT, from)
      right = HgRev(RevType.COMMIT, to)
    elseif from and from ~= "" then
      left = HgRev(RevType.COMMIT, from)
      right = head
    elseif to and to ~= "" then
      left = HgRev.new_null_tree()
      right = HgRev(RevType.COMMIT, to)
    else
      local node, code, stderr = self:exec_sync({"log", "--limit=1", "--template={node}",  "--rev=" .. rev_arg}, self.ctx.toplevel)
      if code ~= 0 and node then
        utils.err(fmt("Failed to parse rev %s: %s", utils.str_quote(rev_arg), stderr))
        return
      end
      left = HgRev(RevType.COMMIT, node[1])

      node, code, stderr = self:exec_sync({"log", "--limit=1", "--template={node}",  "--rev=reverse(" .. rev_arg .. ")"}, self.ctx.toplevel)
      if code ~= 0  and node then
        utils.err(fmt("Failed to parse rev %s: %s", utils.str_quote(rev_arg), stderr))
        return
      end

      right = HgRev(RevType.COMMIT, node[1])
      -- If we refer to a single revision, show diff with working directory
      if node[1] == left.commit then
        right = HgRev(RevType.LOCAL )
      end
    end
  end

  return left, right
end

---@param self HgAdapter
---@param path string
---@param kind vcs.FileKind
---@param commit string?
---@param callback fun(ok: boolean, undo?: string)
HgAdapter.file_restore = async.wrap(function(self, path, kind, commit, callback)
  local _, code
  local abs_path = pl:join(self.ctx.toplevel, path)

  _, code = self:exec_sync({"cat", "--", path}, self.ctx.toplevel)

  local exists_hg = code == 0
  local undo

  if not exists_hg then
    local bn = utils.find_file_buffer(abs_path)
    if bn then
      await(async.scheduler())
      local ok, err = utils.remove_buffer(false, bn)
      if not ok then
        utils.err({
          fmt("Failed to delete buffer '%d'! Aborting file restoration. Error message:", bn),
          err
        }, true)
        callback(false)
        return
      end
    end

    if kind == "working" or kind == "conflicting" then
      -- File is untracked and has no history: delete it from fs.
      local ok, err = pawait(pl.unlink, pl, abs_path)
      if not ok then
        utils.err({
          fmt("Failed to delete file '%s'! Aborting file restoration. Error message:", abs_path),
          err
        }, true)
        callback(false)
        return
      end
    else
      -- File only exists in index
      _, code = self:exec_sync(
        { "rm", "-f", "--", path },
        self.ctx.toplevel
      )
    end
  else
    -- File exists in history: revert
    _, code = self:exec_sync(
      utils.vec_join("revert", commit or (kind == "staged" and "HEAD" or nil), "--", path),
      self.ctx.toplevel
    )
  end

  callback(true, undo)
end)

---Check whether untracked files should be listed.
---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function HgAdapter:show_untracked(opt)
  opt = opt or {}

  -- Only show untracked when comparing the working directory
  if opt.revs then
    if not (opt.revs.right.type == RevType.LOCAL) then
      return false
    end
  end

  -- Check the user provided flag options
  if opt.dv_opt then
    if type(opt.dv_opt.show_untracked) == "boolean" and not opt.dv_opt.show_untracked then
      return false
    end
  end

  -- Fallback to reading custom config option in hgrc
  --    [diffview.nvim]
  --    untracked = no
  local out = self:exec_sync(
    { "log", "--rev=0", "--template={configbool('diffview.nvim', 'untracked', 'True')}" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  return vim.trim(out[1] or "") ~= "False"
end

function HgAdapter:get_files_args(args)
  return utils.vec_join(self:args(), "status", "--print0", "--unknown", "--no-status", "--template={path}\\n", args)
end

HgAdapter.tracked_files = async.wrap(function (self, left, right, args, kind, opt, callback)
  ---@type FileEntry[]
  local files = {}
  ---@type FileEntry[]
  local conflicts = {}
  local log_opt = { label = "HgAdapter:tracked_files()" }

  local namestat_job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "status",
      "--modified",
      "--added",
      "--removed",
      "--deleted",
      "--template={status} {path}\n",
      args
    ),
    cwd = self.ctx.toplevel,
    retry = 2,
    log_opt = log_opt,
  })
  local mergestate_job = Job({
    command = self:bin(),
    args = utils.vec_join(self:args(), "debugmergestate", "-Tjson"),
    cwd = self.ctx.toplevel,
    retry = 2,
    log_opt = log_opt,
  })
  local numstat_job = Job({
    command = self:bin(),
    args = utils.vec_join(self:args(), "diff", "--stat", args),
    cwd = self.ctx.toplevel,
    retry = 2,
    log_opt = log_opt,
  })

  local ok = await(Job.join({ namestat_job, mergestate_job, numstat_job }))

  if not ok or #namestat_job.stdout ~= (#numstat_job.stdout - 1) then
    callback(utils.vec_join(namestat_job.stderr, numstat_job.stderr, mergestate_job.stderr), nil)
    return
  end

  local numstat_out = numstat_job.stdout
  local namestat_out = namestat_job.stdout
  local mergestate_out = mergestate_job.stdout

  local data = {}
  local conflict_map = {}
  local file_info = {}

  -- Last line in numstat is a summary and should not be used
  table.remove(numstat_out, #numstat_out)

  local numstat_info = {}
  for _, s in ipairs(numstat_out) do
      local name, changes, diffstats = s:match("%s*([^|]*)%s+|%s+(%d+)%s+([+-]+)")
      if changes and diffstats then
        local _, adds = diffstats:gsub("+", "")

        numstat_info[name] = {
          additions = tonumber(adds),
          deletions = tonumber(changes) - tonumber(adds),
        }
      end
  end

  for _, s in ipairs(namestat_out) do
    if s ~= " " then
      local status = s:sub(1, 1):gsub("%s", " ")
      local name = vim.trim(s:match("[%a%s]%s*(.*)"))

      local stats = numstat_info[name] or {}

      if not (kind == "staged") then
        file_info[name] = {
          status = status,
          name = name,
          stats = stats,
        }
      end
    end
  end

  local mergestate = vim.json.decode(table.concat(mergestate_out, ''))
  for _, file in ipairs(mergestate[1].files) do
    local base = nil
    for _, extra in ipairs(file.extras) do
      if extra.key == 'ancestorlinknode' then
        base = extra.value
      end
    end
    if file.state == 'u' then
      file_info[file.path].status = 'U'
      file_info[file.path].base = base
      if file.other_path ~= file.path then
        file_info[file.path].oldname = file.other_path
      end
      conflict_map[file.path] = file_info[file.path]
    end
  end

  local nodes = {}
  for _, commit in ipairs(mergestate[1].commits) do
    nodes[commit.name] = commit.node
  end

  for _, f in pairs(file_info) do
    if f.status ~= "U" then
      table.insert(data, f)
    end
  end

  if kind == "working" and next(conflict_map) then
    for _, v in pairs(conflict_map) do
      table.insert(conflicts, FileEntry.with_layout(opt.merge_layout, {
        adapter = self,
        path = v.name,
        oldpath = v.oldname,
        status = "U",
        kind = "conflicting",
        revs = {
          a = self.Rev(RevType.COMMIT, nodes['local']),
          b = self.Rev(RevType.LOCAL),
          c = self.Rev(RevType.COMMIT, nodes.other),
          d = self.Rev(RevType.COMMIT, v.base),
        }
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
end)

HgAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  local job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "status",
      "--print0",
      "--unknown",
      "--no-status",
      "--template={path}\\n"
    ),
    cwd = self.ctx.toplevel,
    log_opt = { label = "HgAdapter:untracked_files()" }
  })

  await(job)

  if job.code ~= 0 then
    callback(job.stderr or {}, nil)
    return
  end

  local files = {}
  for _, s in ipairs(job.stdout) do
    table.insert(
      files,
      FileEntry.with_layout(opt.default_layout, {
        adapter = self,
        path = s,
        status = "?",
        kind = "working",
        revs = {
          a = left,
          b = right,
        }
      })
    )
  end

  callback(nil, files)
end)

---@param self HgAdapter
---@param path string
---@param rev? Rev
---@param callback fun(stderr: string[]?, stdout: string[]?)
HgAdapter.show = async.wrap(function(self, path, rev, callback)
  -- File did not exist, need to return an empty buffer
  if not(rev) or (rev:object_name() == self.Rev.NULL_TREE_SHA) then
    callback(nil, {})
    return
  end

  local job
  job = Job({
    command = self:bin(),
    args = self:get_show_args(path, rev),
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_cond = Job.FAIL_COND.on_empty,
    log_opt = { label = "HgAdapter:show()" },
    on_exit = async.void(function(_, ok, err)
      if not ok or job.code ~= 0 then
        -- Non zero exit code might mean the file was removed
        local out = job.stderr and job.stderr[1] or ''
        if out:match('no such file in rev') then
          callback(nil, {})
        else
          callback(utils.vec_join(err, job.stderr), nil)
        end
        return
      end

      callback(nil, job.stdout)
    end),
  })
  -- Problem: Running multiple 'show' jobs simultaneously may cause them to fail
  -- silently.
  -- Solution: queue them and run them one after another.
  vcs_utils.queue_sync_job(job)
end)

HgAdapter.flags = {
  ---@type FlagOption[]
  switches = {
    FlagOption('-f', '--follow', 'Follow renames'),
    FlagOption('-M', '--no-merges', 'List no merge changesets'),
  },
  ---@type FlagOption[]
  options = {
    FlagOption('=r', '--rev=', 'Revspec', {prompt_label = "(Revspec)"}),
    FlagOption('=l', '--limit=', 'Limit the number of changesets'),
    FlagOption('=u', '--user=', 'Filter on user'),
    FlagOption('=k', '--keyword=', 'Filter by keyword'),
    FlagOption('=b', '--branch=', 'Filter by branch'),
    FlagOption('=B', '--bookmark=', 'Filter by bookmark'),
    FlagOption('=I', '--include=', 'Include files'),
    FlagOption('=E', '--exclude=', 'Exclude files'),
  },
}

-- Add reverse lookups
for _, list in pairs(HgAdapter.flags) do
  for i, option in ipairs(list) do
    list[i] = option
    list[option.key] = option
  end
end

function HgAdapter:is_binary(path, rev)
  -- TODO
  return false
end

-- TODO: implement completion
function HgAdapter:rev_candidates(arg_lead, opt)
  opt = vim.tbl_extend("keep", opt or {}, { accept_range = false }) --[[@as RevCompletionSpec ]]
  logger:lvl(1):debug("[completion] Revision candidates requested")

  local branches = self:exec_sync(
    { "branches", "--template={branch}\n" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  local heads = self:exec_sync(
    { "heads", "--template={node|short}\n" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  local ret = utils.vec_join(heads, branches)

  if opt.accept_range then
    local _, range_end = utils.str_match(arg_lead, {
      "^(%:%:?)()$",
      "^(%:%:?)()[^:]",
      "[^:](%:%:?)()$",
      "[^:](%:%:?)()[^:]",
    })

    if range_end then
      local range_lead = arg_lead:sub(1, range_end - 1)
      ret = vim.tbl_map(function(v)
        return range_lead .. v
      end, ret)
    end
  end

  return ret
end

function HgAdapter:init_completion()
  self.comp.file_history:put({"--rev", "-r"}, function(_, arg_lead)
    return self:rev_candidates(arg_lead, { accept_range = true })
  end)

  self.comp.file_history:put({ "--follow", "-f" })
  self.comp.file_history:put({ "--no-merges", "-M" })
  self.comp.file_history:put({ "--limit", "-l" }, {})

  self.comp.file_history:put({ "--user", "-u" }, {})
  self.comp.file_history:put({ "--keyword", "-k" }, {})

  self.comp.file_history:put({ "--branch", "-b" }, {}) -- TODO: completion
  self.comp.file_history:put({ "--bookmark", "-B" }, {}) -- TODO: completion

  self.comp.file_history:put({"--include", "-I"}, function (_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.file_history:put({"--exclude", "-X"}, function (_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)

end

M.HgAdapter = HgAdapter
return M
