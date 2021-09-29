local Rev = require("diffview.git.rev").Rev
local RevType = require("diffview.git.rev").RevType
local arg_parser = require("diffview.arg_parser")
local git = require("diffview.git.utils")
local utils = require("diffview.utils")
local config = require("diffview.config")
local DiffView = require("diffview.views.diff.diff_view").DiffView
local FileHistoryView = require("diffview.views.file_history.file_history_view").FileHistoryView
local api = vim.api

local M = {}

---@type View[]
M.views = {}

function M.diffview_open(args)
  local argo = arg_parser.parse(args)
  local rev_arg = argo.args[1]
  local paths = {}

  for _, path in ipairs(argo.post_args) do
    table.insert(paths, vim.fn.expand(path))
  end

  local fpath = (
      vim.bo.buftype == ""
        and vim.fn.filereadable(vim.fn.expand("%")) == 1
        and vim.fn.expand("%:p:h")
      or "."
    )
  local cpath = argo:get_flag("C")
  local p = not vim.tbl_contains({ "true", "", nil }, cpath) and cpath or fpath
  if vim.fn.isdirectory(p) ~= 1 then
    p = vim.fn.fnamemodify(p, ":h")
  end

  local git_root = git.toplevel(p)
  if not git_root then
    utils.err(
      string.format("Path not a git repo (or any parent): '%s'", vim.fn.fnamemodify(p, ":."))
    )
    return
  end

  local cached = argo:get_flag("cached", "staged") == "true"
  local left, right = M.parse_revs(git_root, rev_arg, cached)

  ---@type DiffViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag("u", "untracked-files"),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
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
  local argo = arg_parser.parse(args)
  local paths = {}

  for _, path in ipairs(argo.args) do
    table.insert(paths, vim.fn.expand(path))
  end

  if #paths == 0 then
    if vim.bo.buftype == "" then
      table.insert(paths, vim.fn.expand("%:p"))
    else
      utils.err("No target!")
      return
    end
  end

  local p
  if vim.fn.filereadable(paths[1]) == 1 then
    p = vim.fn.isdirectory(paths[1]) ~= 1 and vim.fn.fnamemodify(paths[1], ":h") or paths[1]
  elseif vim.bo.buftype == "" and vim.fn.filereadable(vim.fn.expand("%")) == 1 then
    p = vim.fn.expand("%:p:h")
  else
    p = "."
  end

  local git_root = git.toplevel(p)
  if not git_root then
    utils.err(
      string.format("Path not a git repo (or any parent): '%s'", vim.fn.fnamemodify(paths[1], ":."))
    )
    return
  end

  local cwd = vim.loop.cwd()
  paths = vim.tbl_map(function(pathspec)
    return git.expand_pathspec(git_root, cwd, pathspec)
  end, paths)

  ---@type FileHistoryView
  local v = FileHistoryView({
    git_root = git_root,
    path_args = paths,
    log_options = config.get_config().file_history_panel.log_options,
  })

  if #v.entries == 0 then
    utils.info(string.format("Target has no git history: '%s'", table.concat(paths)))
    return
  end

  table.insert(M.views, v)

  return v
end

---Parse a given rev arg.
---@param git_root string
---@param rev_arg string
---@param cached boolean
---@return Rev left
---@return Rev right
function M.parse_revs(git_root, rev_arg, cached)
  ---@type Rev
  local left
  ---@type Rev
  local right

  local e_git_root = vim.fn.shellescape(git_root)
  local base_cmd = "git -C " .. e_git_root .. " "

  if not rev_arg then
    if cached then
      left = git.head_rev(git_root)
      right = Rev(RevType.INDEX)
    else
      left = Rev(RevType.INDEX)
      right = Rev(RevType.LOCAL)
    end
  elseif rev_arg:match("%.%.%.") then
    left, right = git.symmetric_diff_revs(git_root, rev_arg)
    if not (left or right) then
      return
    end
  else
    local rev_strings = vim.fn.systemlist(
      base_cmd .. "rev-parse --revs-only " .. vim.fn.shellescape(rev_arg)
    )
    if utils.shell_error() then
      utils.err("Failed to parse rev '" .. rev_arg .. "'!")
      utils.err("Git output: " .. vim.fn.join(rev_strings, "\n"))
      return
    elseif #rev_strings == 0 then
      utils.err("Not a git rev: '" .. rev_arg .. "'.")
      return
    end

    if #rev_strings > 1 then
      local left_hash = rev_strings[2]:gsub("^%^", "")
      local right_hash = rev_strings[1]:gsub("^%^", "")
      left = Rev(RevType.COMMIT, left_hash)
      right = Rev(RevType.COMMIT, right_hash)
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      left = Rev(RevType.COMMIT, hash)
      if cached then
        right = Rev(RevType.INDEX)
      else
        right = Rev(RevType.LOCAL)
      end
    end
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
  local StandardView = require("diffview.views.standard.standard_view").StandardView
  ---@type any
  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView) then
      if view.panel:buf_loaded() then
        view.panel:render()
        view.panel:redraw()
      end
    end
  end
end

return M
