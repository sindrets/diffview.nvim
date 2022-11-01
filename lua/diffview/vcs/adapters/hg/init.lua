local oop = require('diffview.oop')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter
local arg_parser = require('diffview.arg_parser')
local utils = require('diffview.utils')
local lazy = require('diffview.lazy')
local config = require('diffview.config')
local async = require("plenary.async")
local logger = require('diffview.logger')
local JobStatus = require('diffview.vcs.utils').JobStatus
local Commit = require("diffview.vcs.adapters.hg.commit").HgCommit
local RevType = require("diffview.vcs.rev").RevType
local HgRev = require('diffview.vcs.adapters.hg.rev').HgRev
local Job = require("plenary.job")
local CountDownLatch = require("diffview.control").CountDownLatch
local FileEntry = require("diffview.scene.file_entry").FileEntry
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local LogEntry = require("diffview.vcs.log_entry").LogEntry

---@type PathLib
local pl = lazy.access(utils, "path")

local M = {}

---@class HgAdapter : VCSAdapter
local HgAdapter = oop.create_class('HgAdapter', VCSAdapter)

HgAdapter.Rev = HgRev
HgAdapter.config_key = "hg"

function M.get_repo_paths(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  for _, path_arg in ipairs(path_args) do
    for _, path in ipairs(pl:vim_expand(path_arg, false, true)) do
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
  local out, code = utils.system_list(vim.tbl_flatten({config.get_config().hg_cmd, {"root"}}), path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

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
    ("Path not a mercurial repo (or any parent): %s")
    :format(table.concat(vim.tbl_map(function(v)
      local rel_path = pl:relative(v, ".")
      return utils.str_quote(rel_path == "" and "." or rel_path)
    end, top_indicators) --[[@as vector ]], ", "))
  ), nil
end

function M.create(toplevel, path_args, cpath)
  return HgAdapter({
    toplevel = toplevel,
    path_args = path_args,
    cpath = cpath,
  })
end

function HgAdapter:init(opt)
  opt = opt or {}
  HgAdapter:super().init(self, opt)

  self.ctx = {
    toplevel = opt.toplevel,
    dir = opt.toplevel,
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

function HgAdapter:file_history_options(range, paths, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local rel_paths

  local cpath = argo:get_flag("C", { no_empty = true, expand = true })
  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths)

  local cwd = cpath or vim.loop.cwd()

  local range_arg = argo:get_flag('rev', { no_empty = true })
  if range_arg then
    -- TODO: check if range is valid
  end

  if range then
    utils.err(
      "Line ranges are not supported for hg!"
    )
    return
  end

  local log_flag_names = {
    { "rev", "r" },
    { "follow", "f" },
    { "no-merges", "M" },
    { "limit", "l" },
    { "user", "u" },
    { "keyword", "k" },
    { "include", "I" },
    { "exclude", "X" },
  }

  ---@type LogOptions
  local log_options = { rev_range = range_arg }
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[self.config_key][key]) ~= "boolean",
      expect_list = names[1] == "L",
    })
    log_options[key] = v
  end

  log_options.path_args = paths

  local ok, opt_description = self:file_history_dry_run(log_options)

  if not ok then
    utils.info({
      ("No hg history for the target(s) given the current options! Targets: %s")
        :format(#rel_paths == 0 and "':(top)'" or table.concat(vim.tbl_map(function(v)
          return "'" .. v .. "'"
        end, rel_paths) --[[@as vector ]], ", ")),
      ("Current options: [ %s ]"):format(opt_description)
    })
    return
  end

  return log_options
end

local function prepare_fh_options(adapter, log_options, single_file)
  local o = log_options
  local rev_range, base

  if log_options.rev then
    rev_range = log_options.rev
  end

  if log_options.base then
    -- TODO
  end

  return {
    rev_range = rev_range,
    base = base,
    path_args = log_options.path_args,
    flags = utils.vec_join(
      (o.follow and single_file) and { "--follow" } or nil,
      o.user and { "--user=" .. o.user } or nil,
      o.limit and { "--limit=" .. o.limit } or nil
    ),
  }
end

---@param log_opt LogOptions
---@return boolean ok, string description
function HgAdapter:file_history_dry_run(log_opt)
  local single_file = self:is_single_file(log_opt.path_args)
  local log_options = config.get_log_options(single_file, log_opt, self.config_key)

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, prepare_fh_options(self, log_options, single_file).flags) -- [[@as vector]]

  local description = utils.vec_join(
    ("Top-level path: '%s'"):format(utils.path:vim_fnamemodify(self.ctx.toplevel, ":~")),
    log_options.rev_range and ("Revision range: '%s'"):format(log_options.rev_range) or nil,
    ("Flags: %s"):format(table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options) --[[@as LogOptions ]]
  log_options.limit = 1
  -- TODO
  options = prepare_fh_options(self, log_options, single_file).flags

  local context = "HgAdapter.file_history_dry_run()"
  local cmd = utils.vec_join(
    "log",
    log_options.rev_range and "--rev=" .. log_options.rev_range or nil,
    options,
    log_options.path_args
  )

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

local function structure_fh_data(namestat_data, numstat_data)
  local right_hash, left_hash, merge_hash = unpack(utils.str_split(namestat_data[1]))
  local time, time_offset = namestat_data[3]:match('(%d+.%d*)([-+]?%d*)')
 
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


---@param state HgAdapter.FHState
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

  local rev_range = state.prepared_log_opts.rev_range and '--rev=' .. state.prepared_log_opts.rev_range or nil

  namestat_job = Job:new({
    command = state.adapter:bin(),
    args = utils.vec_join(
      state.adapter:args(),
      "log",
      rev_range,
      '--template=\\x00\n{node} {p1.node} {ifeq(p2.rev, -1 ,\"\", \"{p2.node}\")}\n{author|person}\n{date}\n{date|age}\n  {separate(", ", tags, topics)}\n  {desc|firstline}\n',
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
      "--template=\\x00\n",
      '--stat',
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
    context = "HgAdapter>incremental_fh_data()",
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

local function parse_fh_data(state)
  local cur = state.cur

  if cur.merge_hash and cur.numstat[1] and #cur.numstat ~= #cur.namestat then
    local job
    local job_spec = {
      command = state.adapter:bin(),
      args = utils.vec_join(
        state.adapter:args(),
        "status",
        "--change",
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
    local context = "HgAdapter.file_history_worker()"
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
  for i = 1, #cur.numstat - 1 do
    local status = cur.namestat[i]:sub(1, 1):gsub("%s", " ")
    local name = cur.namestat[i]:match("[%a%s]%s*(.*)")
    local oldname

    local stats = {}
    local changes, diffstats = cur.numstat[i]:match(".*|%s+(%d+)%s+([+-]+)")
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

    table.insert(files, FileEntry.with_layout(state.opt.default_layout or Diff2Hor, {
      adapter = state.adapter,
      path = name,
      oldpath = oldname,
      status = status,
      stats = stats,
      kind = "working",
      commit = state.commit,
      revs = {
        a = cur.left_hash and HgRev(RevType.COMMIT, cur.left_hash) or HgRev.new_null_tree(),
        b = state.prepared_log_opts.base or HgRev(RevType.COMMIT, cur.right_hash),
      }
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

function HgAdapter:is_single_file(path_args, lflags)
  if path_args and self.ctx.toplevel then
    return #path_args == 1
      and not utils.path:is_dir(path_args[1])
      and #self:exec_sync({ "files", "--", path_args }, self.ctx.toplevel) < 2
  end
  return true
end

function HgAdapter:file_history_worker(thread, log_opt, opt, co_state, callback)
  ---@type LogEntry[]
  local entries = {}
  local data = {}
  local data_idx = 1
  local last_status
  local err_msg

  local single_file = self:is_single_file(log_opt.single_file.path_args, {})

  ---@type LogOptions
  local log_options = config.get_log_options(
    single_file,
    single_file and log_opt.single_file or log_opt.multi_file,
    "hg"
  )

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

  incremental_fh_data(state, data_callback)

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

    local ok, status = parse_fh_data(state)

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

HgAdapter.flags = {
  ---@type FlagOption[]
  switches = {
    {'--follow', '-f', 'Follow renames'},
    {'--no-merges', '-M', 'List no merge changesets'},
  },
  ---@type FlagOption[]
  options = {
    { '=r', '--rev=', 'Revspec', prompt_label = "(Revspec)" },
    { '=l', '--limit=', 'Limit the number of changesets' },
    { '=u', '--user=', 'Filter on user' },
    { '=k', '--keyword=', 'Filter by keyword' },
    { '=b', '--branch=', 'Filter by branch' },
    { '=B', '--bookmark=', 'Filter by bookmark' },
    { '=I', '--include=', 'Include files' },
    { '=E', '--exclude=', 'Exclude files' },
  },
}

for _, list in pairs(HgAdapter.flags) do
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

function HgAdapter:is_binary(path, rev)
  -- TODO
  return false 
end

-- TODO: implement completion
function HgAdapter:rev_completion(arg_lead, opt)
  return { }
end

function HgAdapter:init_completion()
  self.comp.file_history:put({"--rev", "-r"}, function(_, arg_lead)
    return self:rev_completion(arg_lead, { accept_range = true })
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
