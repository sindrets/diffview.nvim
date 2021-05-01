local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local utils = require'diffview.utils'
local FileEntry = require'diffview.file-entry'.FileEntry
local M = {}

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@return FileEntry[]
function M.diff_file_list(git_root, left, right, path_args)
  local files = {}

  local p_args = ""
  if path_args and #path_args > 0 then
    p_args = " --"
    for _, arg in ipairs(path_args) do
      p_args = p_args .. " " .. vim.fn.shellescape(arg)
    end
  end

  local rev_arg = M.rev_to_arg(left, right)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " diff --name-status " .. rev_arg .. p_args
  local names = vim.fn.systemlist(cmd)
  cmd = "git -C " .. vim.fn.shellescape(git_root) .. " diff --numstat " .. rev_arg .. p_args
  local stat_data = vim.fn.systemlist(cmd)

  if not utils.shell_error() then
    for i, s in ipairs(names) do
      local status = s:sub(1, 1):gsub("%s", " ")
      local name = s:match("[%a%s][^%s]*\t(.*)")
      local oldname

      if name:match('\t') ~= nil then
        oldname = name:match('(.*)\t')
        name = name:gsub('^.*\t', '')
      end

      local stats = {
        additions = tonumber(stat_data[i]:match("%d+")),
        deletions = tonumber(stat_data[i]:match("%d+%s+(%d+)"))
      }

      table.insert(files, FileEntry:new({
        path = name,
        oldpath = oldname,
        status = status,
        stats = stats,
        left = left,
        right = right
      }))
    end
  end

  -- If one of the revs are LOCAL, include untracked files.
  if M.has_local(left, right) then
    cmd = "git -C " .. vim.fn.shellescape(git_root) .. " ls-files --others --exclude-standard"
    local untracked = vim.fn.systemlist(cmd)

    if not utils.shell_error() and #untracked > 0 then
      for _, s in ipairs(untracked) do
        table.insert(files, FileEntry:new({
          path = s,
          status = "?",
          left = left,
          right = right
        }))
      end

      utils.merge_sort(files, function (a, b)
        return a.path:lower() < b.path:lower()
      end)
    end
  end

  return files
end

---Convert revs to a git rev arg.
---@param left Rev
---@param right Rev
---@return string
function M.rev_to_arg(left, right)
  assert(left.commit or right.commit, "Can't diff LOCAL against LOCAL!")

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return right.commit .. ".." .. left.commit
  elseif left.type == RevType.LOCAL then
    return right.commit
  else
    return left.commit
  end
end

---Convert revs to string representation.
---@param left Rev
---@param right Rev
function M.rev_to_pretty_string(left, right)
  if left.head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

function M.head_rev(git_root)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " rev-parse HEAD"
  local rev_string = vim.fn.system(cmd)
  if utils.shell_error() then
    return
  end

  local s = vim.trim(rev_string):gsub("^%^", "")
  return Rev:new(RevType.COMMIT, s, true)
end

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.toplevel(path)
  local out = vim.fn.system("git -C " .. vim.fn.shellescape(path) .. " rev-parse --show-toplevel")
  if utils.shell_error() then return nil end
  return vim.trim(out)
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function M.has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

return M
