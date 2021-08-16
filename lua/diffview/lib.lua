local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local arg_parser = require'diffview.arg_parser'
local git = require'diffview.git'
local utils =  require'diffview.utils'
local View = require'diffview.scene.view'.View
local a = vim.api

local M = {}

---@type View[]
M.views = {}

function M.parse_revs(args)
  local argo = arg_parser.parse(args)
  local rev_arg = argo.args[1]
  local paths = {}

  for _, path in ipairs(argo.post_args) do
    table.insert(paths, path)
  end

  ---@type Rev
  local left
  ---@type Rev
  local right

  local cpath = argo:get_flag("C")
  local fpath = (
    vim.bo.buftype == ""
    and vim.fn.filereadable(vim.fn.expand("%f"))
    and vim.fn.expand("%f:p:h")
    or "."
  )
  local p = not vim.tbl_contains({"true", "", nil}, cpath) and cpath or fpath
  if vim.fn.isdirectory(p) ~= 1 then
    p = vim.fn.fnamemodify(p, ":h")
  end

  local git_root = git.toplevel(p)
  if not git_root then
    utils.err("Path not a git repo (or any parent): '" .. p .. "'")
    return
  end

  local e_git_root = vim.fn.shellescape(git_root)
  local base_cmd = "git -C " .. e_git_root .. " "
  local cached = argo:get_flag("cached", "staged") == "true"

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
    if not (left or right) then return end
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

  ---@type ViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag("u", "untracked-files"),
      nil,
      {"all", "normal", "true"},
      {"no", "false"}
    )
  }

  local v = View({
      git_root = git_root,
      rev_arg = rev_arg,
      path_args = paths,
      left = left,
      right = right,
      options = options
    })

  table.insert(M.views, v)

  return v
end

function M.add_view(view)
  table.insert(M.views, view)
end

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
  for _, id in ipairs(a.nvim_list_tabpages()) do
    tabpage_map[id] = true
  end

  local dispose = {}
  for _, view in ipairs(M.views) do
    if not tabpage_map[view.tabpage] then
      -- Need to schedule here because the tabnr's don't update fast enough.
      vim.schedule(function ()
        view:close()
      end)
      table.insert(dispose, view)
    end
  end

  for _, view in ipairs(dispose) do
    M.dispose_view(view)
  end
end

function M.get_current_diffview()
  local tabpage = a.nvim_get_current_tabpage()
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

---Infer the current selected file from the current diffview. If the file panel
---is focused: return the file entry under the cursor. Otherwise return the
---file open in the view. Returns nil if the current tabpage is not a diffview,
---no file is open in the view, or there is no entry under the cursor in the
---file panel.
---@param view View|nil Use the given view rather than looking up the current
---   one.
---@return FileEntry|nil
function M.infer_cur_file(view)
  view = view or M.get_current_diffview()
  if view then
    if view.file_panel:is_focused() then
      return view.file_panel:get_file_at_cursor()
    else
      return view:cur_file()
    end
  end
end

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view.file_panel:buf_loaded() then
      view.file_panel:render()
      view.file_panel:redraw()
    end
  end
end

return M
