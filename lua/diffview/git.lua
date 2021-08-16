local oop = require'diffview.oop'
local utils = require'diffview.utils'
local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local FileEntry = require'diffview.scene.file_entry'.FileEntry
local M = {}

---@class FileDict
---@field working FileEntry[]
---@field staged FileEntry[]
local FileDict = oop.Object
FileDict = oop.create_class("FileDict")

---FileDict constructor.
---@return FileDict
function FileDict:init()
  self.working = {}
  self.staged = {}

  local mt = getmetatable(self)
  local old_index = mt.__index
  mt.__index = function (t, k)
    if type(k) == "number" then
      if k > #t.working then
        return t.staged[k - #t.working]
      else
        return t.working[k]
      end
    else
      return old_index(t, k)
    end
  end
end

function FileDict:size()
  return #self.working + #self.staged
end

function FileDict:iter()
  local i = 0
  local n = #self.working + #self.staged
  return function ()
    i = i + 1
    if i <= n then
      return self[i]
    end
  end
end

function FileDict:ipairs()
  local i = 0
  local n = #self.working + #self.staged
  return function ()
    i = i + 1
    if i <= n then
      ---@type integer, FileEntry
      return i, self[i]
    end
  end
end

local function tracked_files(git_root, left, right, args, kind)
  local files = {}
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " diff --name-status " .. args
  local names = vim.fn.systemlist(cmd)
  cmd = "git -C " .. vim.fn.shellescape(git_root) .. " diff --numstat " .. args
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
        additions = tonumber(stat_data[i]:match("^%d+")),
        deletions = tonumber(stat_data[i]:match("^%d+%s+(%d+)"))
      }

      if not stats.additions or not stats.deletions then
        stats = nil
      end

      table.insert(files, FileEntry({
        path = name,
        oldpath = oldname,
        absolute_path = utils.path_join({git_root, name}),
        status = status,
        stats = stats,
        kind = kind,
        left = left,
        right = right
      }))
    end
  end

  return files
end

local function untracked_files(git_root, left, right)
  local files = {}
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " ls-files --others --exclude-standard"
  local untracked = vim.fn.systemlist(cmd)

  if not utils.shell_error() and #untracked > 0 then
    for _, s in ipairs(untracked) do
      table.insert(files, FileEntry({
            path = s,
            absolute_path = utils.path_join({git_root, s}),
            status = "?",
            kind = "working",
            left = left,
            right = right
        }))
    end
  end

  return files
end

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param options ViewOptions
---@return FileDict
function M.diff_file_list(git_root, left, right, path_args, options)
  ---@type FileDict
  local files = FileDict()

  local p_args = ""
  if path_args and #path_args > 0 then
    p_args = " --"
    for _, arg in ipairs(path_args) do
      p_args = p_args .. " " .. vim.fn.shellescape(arg)
    end
  end

  local rev_arg = M.rev_to_arg(left, right)
  files.working = tracked_files(git_root, left, right, rev_arg .. p_args, "working")

  local show_untracked = options.show_untracked
  if show_untracked == nil then show_untracked = M.show_untracked(git_root) end

  if show_untracked and M.has_local(left, right) then
    local untracked = untracked_files(git_root, left, right)

    if #untracked > 0 then
      files.working = utils.tbl_concat(files.working, untracked)

      utils.merge_sort(files.working, function (a, b)
        return a.path:lower() < b.path:lower()
      end)
    end
  end

  if left.type == RevType.INDEX and right.type == RevType.LOCAL then
    local left_rev = M.head_rev(git_root)
    local right_rev = Rev(RevType.INDEX)
    files.staged = tracked_files(git_root, left_rev, right_rev, "--cached HEAD" .. p_args, "staged")
  end

  return files
end

---Convert revs to a git rev arg.
---@param left Rev
---@param right Rev
---@return string
function M.rev_to_arg(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return left.commit .. ".." .. right.commit
  elseif left.type == RevType.INDEX and right.type == RevType.LOCAL then
    return ""
  elseif left.type == RevType.COMMIT and right.type == RevType.INDEX then
    return "--cached " .. left.commit
  else
    return left.commit
  end
end

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
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
  return Rev(RevType.COMMIT, s, true)
end

---Parse two endpoint, commit revs from a symmetric difference notated rev arg.
---@param git_root string
---@param rev_arg string
---@return Rev left The left rev.
---@return Rev right The right rev.
function M.symmetric_diff_revs(git_root, rev_arg)
  local r1 = rev_arg:match("(.+)%.%.%.") or "HEAD"
  local r2 = rev_arg:match("%.%.%.(.+)") or "HEAD"
  local base_cmd = "git -C " .. vim.fn.shellescape(git_root) .. " "
  local out

  local function err()
    utils.err("Failed to parse rev '" .. rev_arg .. "'!")
    utils.err("Git output: " .. vim.fn.join(out, "\n"))
  end

  out = vim.fn.systemlist(
    base_cmd .. "merge-base "
    .. vim.fn.shellescape(r1) .. " "
    .. vim.fn.shellescape(r2)
  )
  if utils.shell_error() then return err() end
  local left_hash = out[1]:gsub("^%^", "")

  out = vim.fn.systemlist(
    base_cmd .. "rev-parse --revs-only " .. vim.fn.shellescape(r2)
  )
  if utils.shell_error() then return err() end
  local right_hash = out[1]:gsub("^%^", "")

  return Rev(RevType.COMMIT, left_hash), Rev(RevType.COMMIT, right_hash)
end

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.toplevel(path)
  local out = vim.fn.system("git -C " .. vim.fn.shellescape(path) .. " rev-parse --show-toplevel")
  if utils.shell_error() then return nil end
  return vim.trim(out)
end

---Get the path to the .git directory.
---@param path string
---@return string|nil
function M.git_dir(path)
  local out = vim.fn.system(
    "git -C " .. vim.fn.shellescape(path) .. " rev-parse --path-format=absolute --git-dir"
  )
  if utils.shell_error()  then return nil end
  return vim.trim(out)
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function M.has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---Strange trick to check if a file is binary using only git.
---@param git_root string
---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function M.is_binary(git_root, path, rev)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " grep -I --name-only -e . "
  if rev.type == RevType.LOCAL then
    cmd = cmd .. "--untracked"
  elseif rev.type == RevType.INDEX then
    cmd = cmd .. "--cached"
  else
    cmd = cmd .. rev.commit
  end
  vim.fn.system(cmd .. " -- " .. vim.fn.shellescape(path))
  return vim.v.shell_error ~= 0
end

---Check if status for untracked files is disabled for a given git repo.
---@param git_root string
---@return boolean
function M.show_untracked(git_root)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " config --type=bool status.showUntrackedFiles"
  return vim.trim(vim.fn.system(cmd)) ~= "false"
end

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param git_root string
---@param path string
---@param kind "staged"|"working"
---@param commit string
function M.restore_file(git_root, path, kind, commit)
  local base_cmd = "git -C " .. vim.fn.shellescape(git_root) .. " "

  -- Wite file blob into db
  local out = vim.fn.system(base_cmd .. "hash-object -w -- " .. vim.fn.shellescape(path))
  if utils.shell_error() then
    utils.err("Failed to write file blob into the object database. Aborting file restoration.")
    utils.err("Git output: " .. out)
    return
  end

  local undo = (":sp %s | %%!git show %s"):format(
    vim.fn.fnameescape(path),
    out:sub(1, 11)
  )

  -- Revert file
  local cmd = ("%s checkout %s -- %s"):format(
    base_cmd,
    commit or (kind == "staged" and "HEAD" or ""),
    vim.fn.shellescape(path)
  )

  out = vim.fn.system(cmd)
  if utils.shell_error() then
    utils.err("Failed to revert file!")
    utils.err("Git output: " .. out)
    return
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == "staged" and "HEAD" or "index")
  utils.info(("File restored from %s. Undo with %s"):format(rev_name, undo))
end

M.FileDict = FileDict
return M
