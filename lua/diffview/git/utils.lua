local utils = require("diffview.utils")
local FileDict = require("diffview.git.file_dict").FileDict
local Rev = require("diffview.git.rev").Rev
local RevType = require("diffview.git.rev").RevType
local Commit = require("diffview.git.commit").Commit
local LogEntry = require("diffview.git.log_entry").LogEntry
local FileEntry = require("diffview.views.file_entry").FileEntry
local M = {}

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

      if name:match("\t") ~= nil then
        oldname = name:match("(.*)\t")
        name = name:gsub("^.*\t", "")
      end

      local stats = {
        additions = tonumber(stat_data[i]:match("^%d+")),
        deletions = tonumber(stat_data[i]:match("^%d+%s+(%d+)")),
      }

      if not stats.additions or not stats.deletions then
        stats = nil
      end

      table.insert(
        files,
        FileEntry({
          path = name,
          oldpath = oldname,
          absolute_path = utils.path_join({ git_root, name }),
          status = status,
          stats = stats,
          kind = kind,
          left = left,
          right = right,
        })
      )
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
      table.insert(
        files,
        FileEntry({
          path = s,
          absolute_path = utils.path_join({ git_root, s }),
          status = "?",
          kind = "working",
          left = left,
          right = right,
        })
      )
    end
  end

  return files
end

---@param git_root string
---@param path_args string[]
---@param opt LogOptions
---@return LogEntry[]
function M.file_history_list(git_root, path_args, opt)
  ---@type LogEntry[]
  local entries = {}
  local base_cmd = string.format("git -C %s ", vim.fn.shellescape(git_root))
  local single_file = #path_args == 1 and vim.fn.isdirectory(path_args[1]) == 0

  local p_args = ""
  if path_args and #path_args > 0 then
    p_args = ""
    for _, arg in ipairs(path_args) do
      p_args = p_args .. " " .. vim.fn.shellescape(arg)
    end
  end

  local options = string.format(
    "%s %s %s %s %s %s %s %s",
    opt.follow and single_file and "--follow --first-parent" or "-m -c",
    opt.all and "--all" or "",
    opt.merges and "--merges --first-parent" or "",
    opt.no_merges and "--no-merges" or "",
    opt.reverse and "--reverse" or "",
    opt.max_count and ("-n" .. vim.fn.shellescape(opt.max_count)) or "",
    opt.author and ("--author=" .. vim.fn.shellescape(opt.author)) or "",
    opt.grep and ("--grep=" .. vim.fn.shellescape(opt.grep)) or ""
  )

  local cmd = string.format(
    "%s log --pretty='format:%%H %%P%%n%%an%%n%%ad%%n%%ar%%n%%s' "
      .. "--date=raw --name-status %s -- %s",
    base_cmd,
    options,
    p_args
  )
  local status_data = vim.fn.systemlist(cmd)

  cmd = string.format(
    "%s log --pretty='format:%%H %%P%%n%%an%%n%%ad%%n%%ar%%n%%s' "
      .. "--date=raw --numstat %s -- %s",
    base_cmd,
    options,
    p_args
  )
  local num_data = vim.fn.systemlist(cmd)

  if not utils.shell_error() then
    local i = 1
    local offset = 0
    local old_path
    while i <= #num_data do
      local right_hash, left_hash, merge_hash = unpack(utils.str_split(status_data[offset + i]))
      local time, time_offset = unpack(utils.str_split(status_data[offset + i + 2]))
      local commit = Commit({
        hash = right_hash,
        author = status_data[offset + i + 1],
        time = tonumber(time),
        time_offset = time_offset,
        rel_date = status_data[offset + i + 3],
        subject = status_data[offset + i + 4],
      })

      -- 'git log --name-status' doesn't work properly for merge commits. It
      -- lists only an incomplete list of files at best. We need to use 'git
      -- show' to get file statuses for merge commits. And merges do not always
      -- have changes.
      local sdata = status_data
      if merge_hash then
        while sdata[offset + i + 5] and sdata[offset + i + 5] ~= "" do
          offset = offset + 1
        end
        sdata = {}
        local lines = vim.fn.systemlist(
          string.format(
            "%s show --format= -m --first-parent --name-status %s -- %s",
            base_cmd,
            right_hash,
            old_path or p_args
          )
        )
        if #lines == 0 then
          -- Give up: something has been renamed. We can no longer track the
          -- history.
          goto escape
        end
        offset = offset - #lines
        for k = 1, #lines do
          sdata[offset + i + 4 + k] = lines[k]
        end
      end

      local files = {}
      local j = 5
      while i + j <= #num_data and num_data[i + j] ~= "" do
        local status = sdata[offset + i + j]:sub(1, 1):gsub("%s", " ")
        local name = sdata[offset + i + j]:match("[%a%s][^%s]*\t(.*)")
        local oldname

        if name:match("\t") ~= nil then
          oldname = name:match("(.*)\t")
          name = name:gsub("^.*\t", "")
          if single_file then
            old_path = oldname
          end
        end

        local stats = {
          additions = tonumber(num_data[i + j]:match("^%d+")),
          deletions = tonumber(num_data[i + j]:match("^%d+%s+(%d+)")),
        }

        if not stats.additions or not stats.deletions then
          stats = nil
        end

        table.insert(
          files,
          FileEntry({
            path = name,
            oldpath = oldname,
            absolute_path = utils.path_join({ git_root, name }),
            status = status,
            stats = stats,
            kind = "working",
            commit = commit,
            left = Rev(RevType.COMMIT, left_hash),
            right = Rev(RevType.COMMIT, right_hash),
          })
        )
        j = j + 1
      end

      table.insert(
        entries,
        LogEntry({
          path_args = path_args,
          commit = commit,
          files = files,
          single_file = single_file,
        })
      )

      i = i + j + 1
    end
  end

  ::escape::
  return entries
end

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param opt DiffViewOptions
---@return FileDict
function M.diff_file_list(git_root, left, right, path_args, opt)
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

  local show_untracked = opt.show_untracked
  if show_untracked == nil then
    show_untracked = M.show_untracked(git_root)
  end

  if show_untracked and M.has_local(left, right) then
    local untracked = untracked_files(git_root, left, right)

    if #untracked > 0 then
      files.working = utils.tbl_concat(files.working, untracked)

      utils.merge_sort(files.working, function(a, b)
        return a.path:lower() < b.path:lower()
      end)
    end
  end

  if left.type == RevType.INDEX and right.type == RevType.LOCAL then
    local left_rev = M.head_rev(git_root)
    local right_rev = Rev(RevType.INDEX)
    files.staged = tracked_files(git_root, left_rev, right_rev, "--cached HEAD" .. p_args, "staged")
  end

  files:update_file_trees()
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
    base_cmd .. "merge-base " .. vim.fn.shellescape(r1) .. " " .. vim.fn.shellescape(r2)
  )
  if utils.shell_error() then
    return err()
  end
  local left_hash = out[1]:gsub("^%^", "")

  out = vim.fn.systemlist(base_cmd .. "rev-parse --revs-only " .. vim.fn.shellescape(r2))
  if utils.shell_error() then
    return err()
  end
  local right_hash = out[1]:gsub("^%^", "")

  return Rev(RevType.COMMIT, left_hash), Rev(RevType.COMMIT, right_hash)
end

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.toplevel(path)
  local out = vim.fn.system("git -C " .. vim.fn.shellescape(path) .. " rev-parse --show-toplevel")
  if utils.shell_error() then
    return nil
  end
  return vim.trim(out)
end

---Get the path to the .git directory.
---@param path string
---@return string|nil
function M.git_dir(path)
  local out = vim.fn.system(
    "git -C " .. vim.fn.shellescape(path) .. " rev-parse --path-format=absolute --git-dir"
  )
  if utils.shell_error() then
    return nil
  end
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
  local cmd = "git -C "
    .. vim.fn.shellescape(git_root)
    .. " config --type=bool status.showUntrackedFiles"
  return vim.trim(vim.fn.system(cmd)) ~= "false"
end

function M.get_file_status(git_root, path, rev_arg)
  local cmd = "git -C "
    .. vim.fn.shellescape(git_root)
    .. " diff --name-status "
    .. vim.fn.shellescape(rev_arg)
    .. " -- "
    .. vim.fn.shellescape(path)
  local out = vim.fn.system(cmd)
  if not utils.shell_error() and #out > 0 then
    return out:sub(1, 1)
  end
end

function M.get_file_stats(git_root, path, rev_arg)
  local cmd = "git -C "
    .. vim.fn.shellescape(git_root)
    .. " diff --numstat "
    .. vim.fn.shellescape(rev_arg)
    .. " -- "
    .. vim.fn.shellescape(path)
  local out = vim.fn.system(cmd)
  if not utils.shell_error() and #out > 0 then
    local stats = {
      additions = tonumber(out:match("^%d+")),
      deletions = tonumber(out:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end
    return stats
  end
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
  local file_exists = vim.fn.filereadable(utils.path_join({ git_root, path })) == 1
  local base_cmd = "git -C " .. vim.fn.shellescape(git_root) .. " "
  local out

  if file_exists then
    -- Wite file blob into db
    out = vim.fn.system(base_cmd .. "hash-object -w -- " .. vim.fn.shellescape(path))
    if utils.shell_error() then
      utils.err("Failed to write file blob into the object database. Aborting file restoration.")
      utils.err("Git output: " .. out)
      return
    end
  end

  local undo
  if file_exists then
    undo = (":sp %s | %%!git show %s"):format(vim.fn.fnameescape(path), out:sub(1, 11))
  else
    undo = (":!git rm %s"):format(vim.fn.fnameescape(path))
  end

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
