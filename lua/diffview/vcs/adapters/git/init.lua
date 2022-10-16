local oop = require('diffview.oop')
local arg_parser = require('diffview.arg_parser')
local logger = require('diffview.logger')
local utils = require('diffview.utils')
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
