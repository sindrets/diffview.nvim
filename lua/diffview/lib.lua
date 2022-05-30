local lazy = require("diffview.lazy")

---@type DiffView|LazyModule
local DiffView = lazy.access("diffview.views.diff.diff_view", "DiffView")
---@type FileHistoryView|LazyModule
local FileHistoryView = lazy.access("diffview.views.file_history.file_history_view", "FileHistoryView")
---@type Rev|LazyModule
local Rev = lazy.access("diffview.git.rev", "Rev")
---@type RevType|LazyModule
local RevType = lazy.access("diffview.git.rev", "RevType")
---@module "diffview.arg_parser"
local arg_parser = lazy.require("diffview.arg_parser")
---@module "diffview.config"
local config = lazy.require("diffview.config")
---@module "diffview.git.utils"
local git = lazy.require("diffview.git.utils")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")
---@type StandardView|LazyModule
local StandardView = lazy.access("diffview.views.standard.standard_view", "StandardView")

local api = vim.api
local path = utils.path

local M = {}

---@type View[]
M.views = {}

function M.diffview_open(args)
  local default_args = config.get_config().default_args.DiffviewOpen
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local rev_arg = argo.args[1]
  local paths = {}

  for _, path_arg in ipairs(argo.post_args) do
    local magic, pattern = git.pathspec_split(path:vim_expand(path_arg))
    pattern = path:readlink(pattern) or pattern
    table.insert(paths, magic .. pattern)
  end

  local cfile = path:vim_expand("%")
  cfile = path:readlink(cfile) or cfile
  local fpath = (
      vim.bo.buftype == ""
      and path:readable(cfile)
      and path:parent(path:absolute(cfile))
      or path:realpath(".")
    )
  local cpath = argo:get_flag("C")
  if vim.tbl_contains({ "true", "", nil }, cpath) then
    cpath = nil
  end
  local p = cpath and path:realpath(cpath) or fpath
  if not path:is_directory(p) then
    p = path:parent(p)
  end

  local git_root = git.toplevel(p)
  if not git_root then
    utils.err(
      ("Path not a git repo (or any parent): '%s'"):format(path:relative(p, "."))
    )
    return
  end

  local left, right = M.parse_revs(
    git_root,
    rev_arg,
    {
      cached = argo:get_flag("cached", "staged") == "true",
      imply_local = argo:get_flag("imply-local") == "true",
    }
  )

  if not (left and right) then
    return
  end

  ---@type DiffViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag("u", "untracked-files"),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
    selected_file = argo:get_flag("selected-file")
      or (vim.bo.buftype == "" and path:vim_expand("%:p"))
      or nil,
  }

  local v = DiffView({
    git_root = git_root,
    rev_arg = rev_arg,
    path_args = paths,
    left = left,
    right = right,
    options = options,
  })

  table.insert(M.views, v)

  return v
end

function M.file_history(args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local paths = {}
  local rel_paths

  for _, path_arg in ipairs(argo.args) do
    local magic, pattern = git.pathspec_split(path:vim_expand(path_arg))
    pattern = path:readlink(pattern) or pattern
    table.insert(paths, magic .. pattern)
  end

  local cfile = path:vim_expand("%")
  cfile = path:readlink(cfile) or cfile
  local fpath =
      (paths[1] and path:absolute(paths[1]))
      or (
        vim.bo.buftype == ""
        and path:readable(cfile)
        and path:absolute(cfile)
      )
      or path:realpath(".")

  local cpath = argo:get_flag("C")
  if vim.tbl_contains({ "true", "", nil }, cpath) then
    cpath = nil
  end

  if #paths == 0 then
    paths[1] = cpath and path:realpath(cpath) or fpath
  end

  rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or path:relative(v, ".")
  end, paths)

  local p = paths[1]
  local stat = path:stat(p)
  if stat then
    if stat.type ~= "directory" then
      p = path:parent(p)
    end
  else
    p = path:realpath(".")
  end

  local git_root = git.toplevel(p)
  if not git_root then
    utils.err(("Path not a git repo (or any parent): '%s'"):format(rel_paths[1]))
    return
  end

  local cwd = vim.loop.cwd()
  paths = vim.tbl_map(function(pathspec)
    return git.pathspec_expand(git_root, cwd, pathspec)
  end, paths)

  local range_arg = argo:get_flag("range")
  if range_arg then
    local ok = git.verify_rev_arg(git_root, range_arg)
    if not ok then
      utils.err(("Bad revision: '%s'"):format(range_arg))
      return
    end
  end

  local log_options = config.get_config().file_history_panel.log_options
  local ok, opt_description = git.file_history_dry_run(git_root, paths, log_options, { rev_arg = range_arg })

  if not ok then
    utils.info({
      ("No git history for target(s) given the current options! Targets: %s")
        :format(table.concat(vim.tbl_map(function(v)
          return "'" .. v .. "'"
        end, rel_paths), ", ")),
      ("Current options: [ %s ]"):format(opt_description)
    })
    return
  end

  local base
  local base_arg = argo:get_flag("base")
  if base_arg then
    if base_arg == "LOCAL" then
      base = Rev(RevType.LOCAL)
    else
      ---@diagnostic disable-next-line: redefined-local
      local ok, out = git.verify_rev_arg(git_root, base_arg)
      if not ok then
        utils.warn(("Bad base revision, ignoring: '%s'"):format(base_arg))
      else
        base = Rev(RevType.COMMIT, out[1])
      end
    end
  end

  ---@type FileHistoryView
  local v = FileHistoryView({
    git_root = git_root,
    path_args = paths,
    raw_args = argo.args,
    log_options = log_options,
    base = base,
    rev_arg = range_arg,
  })

  table.insert(M.views, v)

  return v
end

---Parse a given rev arg.
---@param git_root string
---@param rev_arg string
---@param opt table
---@return Rev left
---@return Rev right
function M.parse_revs(git_root, rev_arg, opt)
  ---@type Rev
  local left
  ---@type Rev
  local right

  local head = git.head_rev(git_root)

  if not rev_arg then
    if opt.cached then
      left = head or Rev.new_null_tree()
      right = Rev(RevType.INDEX)
    else
      left = Rev(RevType.INDEX)
      right = Rev(RevType.LOCAL)
    end
  elseif rev_arg:match("%.%.%.") then
    left, right = git.symmetric_diff_revs(git_root, rev_arg)
    if not (left or right) then
      return
    elseif opt.imply_local then
      left, right = M.imply_local(left, right, head)
    end
  else
    local rev_strings, code, stderr = utils.system_list(
      { "git", "rev-parse", "--revs-only", rev_arg }, git_root
    )
    if code ~= 0 then
      utils.err(utils.vec_join(
        ("Failed to parse rev '%s'!"):format(rev_arg),
        "Git output: ",
        stderr
      ))
      return
    elseif #rev_strings == 0 then
      utils.err("Bad revision: '" .. rev_arg .. "'")
      return
    end

    local is_range = git.is_rev_arg_range(rev_arg)

    if is_range then
      local right_hash = rev_strings[1]:gsub("^%^", "")
      right = Rev(RevType.COMMIT, right_hash)
      if #rev_strings > 1 then
        local left_hash = rev_strings[2]:gsub("^%^", "")
        left = Rev(RevType.COMMIT, left_hash)
      else
        left = Rev.new_null_tree()
      end

      if opt.imply_local then
        left, right = M.imply_local(left, right, head)
      end
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      left = Rev(RevType.COMMIT, hash)
      if opt.cached then
        right = Rev(RevType.INDEX)
      else
        right = Rev(RevType.LOCAL)
      end
    end
  end

  return left, right
end

---@param left Rev
---@param right Rev
---@param head Rev
---@return Rev, Rev
function M.imply_local(left, right, head)
  if left.commit == head.commit then
    left = Rev(RevType.LOCAL)
  end
  if right.commit == head.commit then
    right = Rev(RevType.LOCAL)
  end
  return left, right
end

---@param view View
function M.add_view(view)
  table.insert(M.views, view)
end

---@param view View
function M.dispose_view(view)
  for j, v in ipairs(M.views) do
    if v == view then
      table.remove(M.views, j)
      return
    end
  end
end

---Close and dispose of views that have no tabpage.
function M.dispose_stray_views()
  local tabpage_map = {}
  for _, id in ipairs(api.nvim_list_tabpages()) do
    tabpage_map[id] = true
  end

  local dispose = {}
  for _, view in ipairs(M.views) do
    if not tabpage_map[view.tabpage] then
      -- Need to schedule here because the tabnr's don't update fast enough.
      vim.schedule(function()
        view:close()
      end)
      table.insert(dispose, view)
    end
  end

  for _, view in ipairs(dispose) do
    M.dispose_view(view)
  end
end

---Get the currently open Diffview.
---@return View
function M.get_current_view()
  local tabpage = api.nvim_get_current_tabpage()
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end

  return nil
end

function M.tabpage_to_view(tabpage)
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end
end

---Get the first tabpage that is not a view. Tries the previous tabpage first.
---If there are no non-view tabpages: returns nil.
---@return number|nil
function M.get_prev_non_view_tabpage()
  local tabs = api.nvim_list_tabpages()
  if #tabs > 1 then
    local seen = {}
    for _, view in ipairs(M.views) do
      seen[view.tabpage] = true
    end

    local prev_tab = utils.tabnr_to_id(vim.fn.tabpagenr("#")) or -1
    if api.nvim_tabpage_is_valid(prev_tab) and not seen[prev_tab] then
      return prev_tab
    else
      for _, id in ipairs(tabs) do
        if not seen[id] then
          return id
        end
      end
    end
  end
end

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      if view.panel:buf_loaded() then
        view.panel:render()
        view.panel:redraw()
      end
    end
  end
end

return M
