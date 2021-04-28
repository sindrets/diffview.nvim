local utils = require'difftool.utils'
local M = {}

---@class FileEntry
---@field path string
---@field status string

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@return FileEntry[]
function M.diff_file_list(git_root, left, right)
  local files = {}
  local rev_arg = M.rev_to_arg(left, right)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " diff --name-status " .. rev_arg
  local names = vim.fn.systemlist(cmd)

  if not utils.shell_error() then
    for _, s in ipairs(names) do
      local status = s:sub(1, 2)
      local name = s:match("[%a%s][%a%s]%s+(.*)")
      table.insert(files, { path = name, status = status })
    end
  end

  if M.has_local(left, right) then
    cmd = "git -C " .. vim.fn.shellescape(git_root) .. " ls-files --others --exclude-standard"
    local untracked = vim.fn.systemlist(cmd)

    if not utils.shell_error() and #untracked > 0 then
      for _, s in ipairs(untracked) do
        table.insert(files, { path = s, status = "??"})
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
  local rev = require'difftool.rev'

  assert(left.commit or right.commit, "Can't diff LOCAL against LOCAL!")

  if left.type == rev.RevType.COMMIT and right.type == rev.RevType.COMMIT then
    return right.commit .. ".." .. left.commit
  elseif left.type == rev.RevType.LOCAL then
    return right.commit
  else
    return left.commit
  end
end

function M.has_local(left, right)
  local rev = require'difftool.rev'
  return left.type == rev.RevType.LOCAL or right.type == rev.RevType.LOCAL
end

return M
