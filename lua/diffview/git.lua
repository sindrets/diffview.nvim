local utils = require'diffview.utils'
local FileEntry = require'diffview.file-entry'.FileEntry
local M = {}

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
      local status = s:sub(1, 1):gsub("%s", " ")
      local name = s:match("[%a%s][^%s]*\t(.*)")
      local oldname
      if name:match('\t') ~= nil then
        oldname = name:match('(.*)\t')
        name = name:gsub('^.*\t', '')
      end
      table.insert(files, FileEntry:new({
        path = name,
        status = status,
        oldpath = oldname,
        left = left,
        right = right
      }))
    end
  end

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
  local rev = require'diffview.rev'

  assert(left.commit or right.commit, "Can't diff LOCAL against LOCAL!")

  if left.type == rev.RevType.COMMIT and right.type == rev.RevType.COMMIT then
    return right.commit .. ".." .. left.commit
  elseif left.type == rev.RevType.LOCAL then
    return right.commit
  else
    return left.commit
  end
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function M.has_local(left, right)
  local rev = require'diffview.rev'
  return left.type == rev.RevType.LOCAL or right.type == rev.RevType.LOCAL
end

return M
