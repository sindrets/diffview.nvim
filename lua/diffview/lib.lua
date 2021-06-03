local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local arg_parser = require'diffview.arg-parser'
local git = require'diffview.git'
local utils =  require'diffview.utils'
local View = require'diffview.view'.View
local a = vim.api

local M = {}

---@type View[]
M.views = {}

function M.parse_revs(args)
  local argo = arg_parser.parse(args)
  local rev_arg = argo.args[1]
  local paths = {}

  for _, path in ipairs(argo.post_args) do
    table.insert(paths, vim.fn.fnamemodify(path, ":p"))
  end

  ---@type Rev
  local left
  ---@type Rev
  local right

  local p = paths[1] or "."
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
      right = Rev:new(RevType.INDEX)
    else
      left = Rev:new(RevType.INDEX)
      right = Rev:new(RevType.LOCAL)
    end
  else
    local rev_strings = vim.fn.systemlist(base_cmd .. "rev-parse --revs-only " .. vim.fn.shellescape(rev_arg))
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
      left = Rev:new(RevType.COMMIT, left_hash)
      right = Rev:new(RevType.COMMIT, right_hash)
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      left = Rev:new(RevType.COMMIT, hash)
      if cached then
        right = Rev:new(RevType.INDEX)
      else
        right = Rev:new(RevType.LOCAL)
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

  local v = View:new({
      git_root = git_root,
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

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view.file_panel:buf_loaded() then
      view.file_panel:render()
      view.file_panel:redraw()
    end
  end
end

return M
