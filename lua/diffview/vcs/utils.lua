local FileDict = require("diffview.vcs.file_dict").FileDict
local RevType = require("diffview.vcs.rev").RevType
local Scanner = require("diffview.scanner")
local Semaphore = require("diffview.control").Semaphore
local async = require("diffview.async")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@enum JobStatus
local JobStatus = oop.enum({
  SUCCESS  = 1,
  PROGRESS = 2,
  ERROR    = 3,
  KILLED   = 4,
  FATAL    = 5,
})

---@type diffview.Job[]
local sync_jobs = {}
local job_queue_sem = Semaphore(1)

---@param job diffview.Job
M.resume_sync_queue = async.void(function(job)
  local permit = await(job_queue_sem:acquire()) --[[@as Permit ]]
  local idx = utils.vec_indexof(sync_jobs, job)
  if idx > -1 then
    table.remove(sync_jobs, idx)
  end
  permit:forget()

  if sync_jobs[1] and not sync_jobs[1]:is_started() then
    sync_jobs[1]:start()
  end
end)

---@param job diffview.Job
M.queue_sync_job = async.void(function(job)
  job:on_exit(function()
    M.resume_sync_queue(job)
  end)

  local permit = await(job_queue_sem:acquire()) --[[@as Permit ]]
  table.insert(sync_jobs, job)

  if #sync_jobs == 1 then
    job:start()
  end

  permit:forget()
end)

---Get a list of files modified between two revs.
---@param adapter VCSAdapter
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param dv_opt DiffViewOptions
---@param opt vcs.adapter.LayoutOpt
---@param callback function
---@return string[]? err
---@return FileDict?
M.diff_file_list = async.wrap(function(adapter, left, right, path_args, dv_opt, opt, callback)
  ---@type FileDict
  local files = FileDict()
  local rev_args = adapter:rev_to_args(left, right)
  local errors = {}

  ;(function()
    local err, tfiles, tconflicts = await(
      adapter:tracked_files(
        left,
        right,
        utils.vec_join(rev_args, "--", path_args),
        "working",
        opt
      )
    )

    if err then
      errors[#errors+1] = err
      utils.err("Failed to get git status for tracked files!", true)
      return
    end

    files:set_working(tfiles)
    files:set_conflicting(tconflicts)

    if not adapter:show_untracked({
        dv_opt = dv_opt,
        revs = { left = left, right = right },
      })
    then return end

    ---@diagnostic disable-next-line: redefined-local
    local err, ufiles = await(adapter:untracked_files(left, right, opt))

    if err then
      errors[#errors+1] = err
      utils.err("Failed to get git status for untracked files!", true)
    else
      files:set_working(utils.vec_join(files.working, ufiles))

      utils.merge_sort(files.working, function(a, b)
        return a.path:lower() < b.path:lower()
      end)
    end
  end)()

  if left.type == RevType.STAGE and right.type == RevType.LOCAL then
    local left_rev = adapter:head_rev() or adapter.Rev.new_null_tree()
    local right_rev = adapter.Rev(RevType.STAGE, 0)
    ---@diagnostic disable-next-line: redefined-local
    local err, tfiles = await(
      adapter:tracked_files(
        left_rev,
        right_rev,
        utils.vec_join("--cached", left_rev.commit, "--", path_args),
        "staged",
        opt
      )
    )

    if err then
      errors[#errors+1] = err
      utils.err("Failed to get git status for staged files!", true)
    else
      files:set_staged(tfiles)
    end
  end

  if #errors > 0 then
    callback(utils.vec_join(unpack(errors)), nil)
    return
  end

  files:update_file_trees()
  callback(nil, files)
end, 7)

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param adapter VCSAdapter
---@param path string
---@param kind vcs.FileKind
---@param commit? string
M.restore_file = async.void(function(adapter, path, kind, commit)
  local ok, undo = await(adapter:file_restore(path, kind, commit))

  if not ok then
    utils.err("Failed to revert file! See ':DiffviewLog' for details.", true)
    return
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == "staged" and "HEAD" or "index")
  local msg = fmt("File restored from %s. %s", rev_name, undo and ("Undo with " .. undo) or "")

  logger:info(msg)
  utils.info(msg, true)
end)

--[[
Standard change:

diff --git a/lua/diffview/health.lua b/lua/diffview/health.lua
index c05dcda..07bdd33 100644
--- a/lua/diffview/health.lua
+++ b/lua/diffview/health.lua
@@ -48,7 +48,7 @@ function M.check()

Rename with change:

diff --git a/test/index_watcher_spec.lua b/test/gitdir_watcher_spec.lua
similarity index 94%
rename from test/index_watcher_spec.lua
rename to test/gitdir_watcher_spec.lua
index 008beab..66116dc 100644
--- a/test/index_watcher_spec.lua
+++ b/test/gitdir_watcher_spec.lua
@@ -17,7 +17,7 @@ local get_buf_name    = helpers.curbufmeths.get_name
--]]

local DIFF_HEADER = [[^diff %-%-git ]]
local DIFF_SIMILARITY = [[^similarity index (%d+)%%]]
local DIFF_INDEX = { [[^index (%x-)%.%.(%x-) (%d+)]], [[^index (%x-)%.%.(%x-)]] }
local DIFF_PATH_OLD = { [[^%-%-%- a/(.*)]], [[^%-%-%- (/dev/null)]] }
local DIFF_PATH_NEW = { [[^%+%+%+ b/(.*)]], [[^%+%+%+ (/dev/null)]] }
local DIFF_HUNK_HEADER = [[^@@+ %-(%d+),(%d+) %+(%d+),(%d+) @@+]]

---@class diff.Hunk
---@field old_row integer
---@field old_size integer
---@field new_row integer
---@field new_size integer
---@field common_content string[]
---@field old_content { [1]: integer, [2]: string[] }[]
---@field new_content { [1]: integer, [2]: string[] }[]

---@param scanner Scanner
---@param old_row integer
---@param old_size integer
---@param new_row integer
---@param new_size integer
---@return diff.Hunk
local function parse_diff_hunk(scanner, old_row, old_size, new_row, new_size)
  local ret = {
    old_row = old_row,
    old_size = old_size,
    new_row = new_row,
    new_size = new_size,
    common_content = {},
    old_content = {},
    new_content = {},
  }

  local common_idx, old_offset, new_offset = 1, 0, 0
  local line = scanner:peek_line()
  local cur_start = (line or ""):match("^([%+%- ])")

  while cur_start do
    line = scanner:next_line() --[[@as string ]]

    if cur_start == " " then
      ret.common_content[#ret.common_content + 1] = line:sub(2) or ""
      common_idx = common_idx + 1

    elseif cur_start == "-" then
      local content = { line:sub(2) or "" }

      while (scanner:peek_line() or ""):sub(1, 1) == "-" do
        content[#content + 1] = scanner:next_line():sub(2) or ""
      end

      ret.old_content[#ret.old_content + 1] = { common_idx + old_offset, content }
      old_offset = old_offset + #content

    elseif cur_start == "+" then
      local content = { line:sub(2) or "" }

      while (scanner:peek_line() or ""):sub(1, 1) == "+" do
        content[#content + 1] = scanner:next_line():sub(2) or ""
      end

      ret.new_content[#ret.new_content + 1] = { common_idx + new_offset, content }
      new_offset = new_offset + #content
    end

    cur_start = (scanner:peek_line() or ""):match("^([%+%- ])")
  end

  return ret
end

---@class diff.FileEntry
---@field renamed boolean
---@field similarity? integer
---@field dissimilarity? integer
---@field index_old? integer
---@field index_new? integer
---@field mode? integer
---@field old_mode? integer
---@field new_mode? integer
---@field deleted_file_mode? integer
---@field new_file_mode? integer
---@field path_old? string
---@field path_new? string
---@field hunks diff.Hunk[]

---@param scanner Scanner
---@return diff.FileEntry
local function parse_file_diff(scanner)
  ---@type diff.FileEntry
  local ret = { renamed = false, hunks = {} }

  -- The current line will here be the diff header

  -- Extended git diff headers
  while scanner:peek_line() and
    not utils.str_match(scanner:peek_line() or "", { DIFF_HEADER, DIFF_HUNK_HEADER })
  do
    -- Extended header lines:
    -- old mode <mode>
    -- new mode <mode>
    -- deleted file mode <mode>
    -- new file mode <mode>
    -- copy from <path>
    -- copy to <path>
    -- rename from <path>
    -- rename to <path>
    -- similarity index <number>
    -- dissimilarity index <number>
    -- index <hash>..<hash> <mode>
    --
    -- Note: Combined diffs have even more variations

    local last_line_idx = scanner:cur_line_idx()

    -- Similarity
    local similarity = (scanner:peek_line() or ""):match(DIFF_SIMILARITY)
    if similarity then
      ret.similarity = tonumber(similarity) or -1
      scanner:next_line()
    end

    -- Dissimilarity
    local dissimilarity = (scanner:peek_line() or ""):match([[^dissimilarity index (%d+)%%]])
    if dissimilarity then
      ret.dissimilarity = tonumber(dissimilarity) or -1
      scanner:next_line()
    end

    -- Renames
    local rename_from = (scanner:peek_line() or ""):match([[^rename from (.*)]])
    if rename_from then
      ret.renamed = true
      ret.path_old = rename_from
      scanner:skip_line()
      ret.path_new = (scanner:next_line() or ""):match([[^rename to (.*)]])
    end

    -- Copies
    local copy_from = (scanner:peek_line() or ""):match([[^copy from (.*)]])
    if copy_from then
      ret.path_old = copy_from
      scanner:skip_line()
      ret.path_new = (scanner:next_line() or ""):match([[^copy to (.*)]])
    end

    -- Old mode
    local old_mode = (scanner:peek_line() or ""):match([[^old mode (%d+)]])
    if old_mode then
      ret.old_mode = old_mode
      scanner:next_line()
    end

    -- New mode
    local new_mode = (scanner:peek_line() or ""):match([[^new mode (%d+)]])
    if new_mode then
      ret.new_mode = new_mode
      scanner:next_line()
    end

    -- Deleted file
    local deleted_file_mode = (scanner:peek_line() or ""):match([[^deleted file mode (%d+)]])
    if deleted_file_mode then
      ret.old_file_mode = deleted_file_mode
      scanner:next_line()
    end

    -- New file
    local new_file_mode = (scanner:peek_line() or ""):match([[^new file mode (%d+)]])
    if new_file_mode then
      ret.new_file_mode = new_file_mode
      scanner:next_line()
    end

    -- Index
    local index_old, index_new, mode = utils.str_match(scanner:peek_line() or "", DIFF_INDEX)
    if index_old then
      ret.index_old = index_old
      ret.index_new = index_new
      ret.mode = mode
      scanner:next_line()
    end

    -- Paths
    local path_old = utils.str_match(scanner:peek_line() or "", DIFF_PATH_OLD)
    if path_old then
      if not ret.path_old then
        ret.path_old = path_old ~= "/dev/null" and path_old or nil
        scanner:skip_line()
        local path_new = utils.str_match(scanner:next_line() or "", DIFF_PATH_NEW)
        ret.path_new = path_new ~= "/dev/null" and path_new or nil
      else
        scanner:skip_line(2)
      end
    end

    if last_line_idx == scanner:cur_line_idx() then
      -- Non-git patches don't have the extended header lines
      break
    end
  end

  -- Hunks
  local line = scanner:peek_line()
  while line and not line:match(DIFF_HEADER) do
    local old_row, old_size, new_row, new_size = line:match(DIFF_HUNK_HEADER)
    scanner:next_line() -- Current line is now the hunk header

    if old_row then
      table.insert(ret.hunks, parse_diff_hunk(
        scanner,
        tonumber(old_row) or -1,
        tonumber(old_size) or -1,
        tonumber(new_row) or -1,
        tonumber(new_size) or -1
      ))
    end

    line = scanner:peek_line()
  end

  return ret
end

---Parse a diff patch.
---@param lines string[]
---@return diff.FileEntry[]
function M.parse_diff(lines)
  local ret = {}
  local scanner = Scanner(lines)

  while scanner:peek_line() do
    local line = scanner:next_line() --[[@as string ]]
    -- TODO: Diff headers and patch format can take a few different forms. I.e. combined diffs
    if line:match(DIFF_HEADER) then
      table.insert(ret, parse_file_diff(scanner))
    end
  end

  return ret
end

---Build either the old or the new version of a diff hunk.
---@param hunk diff.Hunk
---@param version "old"|"new"
---@return string[]
function M.diff_build_hunk(hunk, version)
  local vcontent = version == "old" and hunk.old_content or hunk.new_content
  local size = version == "old" and hunk.old_size or hunk.new_size
  local common_idx = 1
  local chunk_idx = 1

  local ret = {}
  local i = 1

  while i <= size do
    local chunk = vcontent[chunk_idx]

    if chunk and chunk[1] == i then
      for _, line in ipairs(chunk[2]) do
        ret[#ret + 1] = line
      end

      i = i + (#chunk[2] - 1)
      chunk_idx = chunk_idx + 1
    else
      ret[#ret + 1] = hunk.common_content[common_idx]
      common_idx = common_idx + 1
    end

    i = i + 1
  end

  return ret
end

local CONFLICT_START = [[^<<<<<<< ]]
local CONFLICT_BASE = [[^||||||| ]]
local CONFLICT_SEP = [[^=======$]]
local CONFLICT_END = [[^>>>>>>> ]]

---@class ConflictRegion
---@field first integer
---@field last integer
---@field ours { first: integer, last: integer, content?: string[] }
---@field base { first: integer, last: integer, content?: string[] }
---@field theirs { first: integer, last: integer, content?: string[] }

---@param lines string[]
---@param winid? integer
---@return ConflictRegion[] conflicts
---@return ConflictRegion? cur_conflict The conflict under the cursor in the given window.
---@return integer cur_conflict_idx Index of the current conflict. Will be 0 if the cursor is before the first conflict, and `#conflicts + 1` if the cursor is after the last conflict.
function M.parse_conflicts(lines, winid)
  local ret = {}
  local has_start, has_base, has_sep = false, false, false
  local cur, cursor, cur_conflict, cur_idx

  if winid and api.nvim_win_is_valid(winid) then
    cursor = api.nvim_win_get_cursor(winid)
  end

  local function handle(data)
    local first = math.min(
     data.ours.first or math.huge,
     data.base.first or math.huge,
     data.theirs.first or math.huge
    )

    if first == math.huge then return end

    local last = math.max(
      data.ours.last or -1,
      data.base.last or -1,
      data.theirs.last or -1
    )

    if last == -1 then return end

    if data.ours.first and data.ours.last and data.ours.first < data.ours.last then
      data.ours.content = utils.vec_slice(lines, data.ours.first + 1, data.ours.last)
    end

    if data.base.first and data.base.last and data.base.first < data.base.last then
      data.base.content = utils.vec_slice(lines, data.base.first + 1, data.base.last)
    end

    if data.theirs.first and data.theirs.last and data.theirs.first < data.theirs.last - 1 then
      data.theirs.content = utils.vec_slice(lines, data.theirs.first + 1, data.theirs.last - 1)
    end

    if cursor then
      if not cur_conflict and cursor[1] >= first and cursor[1] <= last then
        cur_conflict = data
        cur_idx = #ret + 1
      elseif cursor[1] > last then
        cur_idx = (cur_idx or 0) + 1
      end
    end

    data.first = first
    data.last = last
    ret[#ret + 1] = data
  end

  local function new_cur()
    return {
      ours = {},
      base = {},
      theirs = {},
    }
  end

  cur = new_cur()

  for i, line in ipairs(lines) do
    if line:match(CONFLICT_START) then
      if has_start then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_start = true
      cur.ours.first = i
      cur.ours.last = i
    elseif line:match(CONFLICT_BASE) then
      if has_base then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_base = true
      cur.base.first = i
      cur.ours.last = i - 1
    elseif line:match(CONFLICT_SEP) then
      if has_sep then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_sep = true
      cur.theirs.first = i
      cur.theirs.last = i

      if has_base then
        cur.base.last = i - 1
      else
        cur.ours.last = i - 1
      end
    elseif line:match(CONFLICT_END) then
      if not has_sep then
        if has_base then
          cur.base.last = i - 1
        elseif has_start then
          cur.ours.last = i - 1
        end
      end

      cur.theirs.first = cur.theirs.first or i
      cur.theirs.last = i
      handle(cur)
      cur, has_start, has_base, has_sep = new_cur(), false, false, false
    end
  end

  handle(cur)

  if cursor and cur_idx then
    if cursor[1] > ret[#ret].last then
      cur_idx = #ret + 1
    end
  end

  return ret, cur_conflict, cur_idx or 0
end

---@param version { major: integer, minor: integer, patch: integer }
---@param required { major: integer, minor: integer, patch: integer }
---@return boolean
function M.check_semver(version, required)
  if version.major ~= required.major then
    return version.major > required.major
  elseif version.minor ~= required.minor then
    return version.minor > required.minor
  elseif version.patch ~= required.patch then
    return version.patch > required.patch
  end
  return true
end


M.JobStatus = JobStatus
return M
