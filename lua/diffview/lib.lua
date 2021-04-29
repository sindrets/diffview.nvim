local rev = require'diffview.rev'
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

  local git_root = M.git_toplevel(paths[1] or ".")
  if not git_root then
    utils.err("Path not a git repo (or any parent): '" .. paths[1] .. "'")
    return
  end

  local e_git_root = vim.fn.shellescape(git_root)
  local base_cmd = "git -C " .. e_git_root .. " "

  if not rev_arg then
    -- Diff LOCAL and HEAD
    local rev_string = vim.fn.system(base_cmd .. "rev-parse HEAD")
    if utils.shell_error() then
      utils.err("Git repo has no HEAD! Can't perform diff for '" .. git_root .. "'.")
      return
    end

    left = rev.Rev:new(rev.RevType.COMMIT, vim.trim(rev_string):gsub("^%^", ""))
    right = rev.Rev:new(rev.RevType.LOCAL)
  else
    local rev_strings = vim.fn.systemlist(base_cmd .. "rev-parse --no-flags " .. vim.fn.shellescape(rev_arg))
    if utils.shell_error() then
      utils.err("Failed to parse rev '" .. rev_arg .. "'!")
      utils.err("Git output: " .. vim.fn.join(rev_strings, "\n"))
      return
    end

    if #rev_strings > 1 then
      -- Diff COMMIT to COMMIT
      left = rev.Rev:new(rev.RevType.COMMIT, rev_strings[1]:gsub("^%^", ""))
      right = rev.Rev:new(rev.RevType.COMMIT, rev_strings[2]:gsub("^%^", ""))
    else
      -- Diff LOCAL and COMMIT
      left = rev.Rev:new(rev.RevType.COMMIT, rev_strings[1]:gsub("^%^", ""))
      right = rev.Rev:new(rev.RevType.LOCAL)
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

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.git_toplevel(path)
  local out = vim.fn.system("git -C " .. vim.fn.shellescape(path) .. " rev-parse --show-toplevel")
  if utils.shell_error() then return nil end
  return vim.trim(out)
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

return M
