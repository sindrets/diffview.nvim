local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local git = require'diffview.git'
local utils =  require'diffview.utils'
local View = require'diffview.view'.View
local a = vim.api

local M = {}

---@type View[]
M.views = {}

function M.parse_revs(args)
  local paths = {}
  local rev_arg
  local divider_idx

  for i, v in ipairs(args) do
    if v == "--" then
      divider_idx = i
      for j = i + 1, #args do
        table.insert(paths, vim.fn.fnamemodify(args[j], ":p"))
      end
      break
    end
  end

  if #paths > 0 then
    if divider_idx > 1 then
      rev_arg = args[1]
    end
  elseif #args >= 1 then
    rev_arg = args[1]
  end

  ---@type Rev
  local left
  ---@type Rev
  local right

  local git_root = git.toplevel(paths[1] or ".")
  if not git_root then
    utils.err("Path not a git repo (or any parent): '" .. (paths[1] or ".") .. "'")
    return
  end

  local e_git_root = vim.fn.shellescape(git_root)
  local base_cmd = "git -C " .. e_git_root .. " "

  if not rev_arg then
    -- Diff LOCAL and HEAD
    left = git.head_rev(git_root)
    right = Rev:new(RevType.LOCAL)

    if not left then
      utils.err("Git repo has no HEAD! Can't perform diff for '" .. git_root .. "'.")
      return
    end
  else
    local rev_strings = vim.fn.systemlist(base_cmd .. "rev-parse --revs-only " .. vim.fn.shellescape(rev_arg))
    if utils.shell_error() then
      utils.err("Failed to parse rev '" .. rev_arg .. "'!")
      utils.err("Git output: " .. vim.fn.join(rev_strings, "\n"))
      return
    end

    if #rev_strings > 1 then
      -- Diff COMMIT to COMMIT
      local left_hash = rev_strings[2]:gsub("^%^", "")
      local right_hash = rev_strings[1]:gsub("^%^", "")
      left = Rev:new(RevType.COMMIT, left_hash)
      right = Rev:new(RevType.COMMIT, right_hash)
    else
      -- Diff LOCAL and COMMIT
      local hash = rev_strings[1]:gsub("^%^", "")
      left = Rev:new(RevType.COMMIT, hash)
      right = Rev:new(RevType.LOCAL)
    end
  end

  local v = View:new({
      git_root = git_root,
      path_args = paths,
      left = left,
      right = right
    })

  table.insert(M.views, v)

  return v
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
