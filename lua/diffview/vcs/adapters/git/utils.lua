local CountDownLatch = require("diffview.control").CountDownLatch
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileDict = require("diffview.vcs.file_dict").FileDict
local FileEntry = require("diffview.scene.file_entry").FileEntry
local Job = require("plenary.job")
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local Rev = require("diffview.vcs.rev").Rev
local RevType = require("diffview.vcs.rev").RevType
local async = require("plenary.async")
local logger = require("diffview.logger")
local utils = require("diffview.utils")
local JobStatus = require("diffview.vcs.utils").JobStatus

local api = vim.api

local M = {}


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
---@return integer cur_conflict_idx Index of the current conflict. Will be 0 if the cursor if before the first conflict, and `#conflicts + 1` if the cursor is after the last conflict.
function M.parse_conflicts(lines, winid)
  local ret = {}
  local has_start, has_base, has_sep = false, false, false
  local cur, cursor, cur_conflict, cur_idx

  if winid and api.nvim_win_is_valid(winid) then
    cursor = api.nvim_win_get_cursor(winid)
  end

  local function handle(data)
    local first = math.huge
    local last = -1

    first = math.min(data.ours.first or math.huge, first)
    first = math.min(data.base.first or math.huge, first)
    first = math.min(data.theirs.first or math.huge, first)

    if first == math.huge then return end

    last = math.max(data.ours.last or -1, -1)
    last = math.max(data.base.last or -1, -1)
    last = math.max(data.theirs.last or -1, -1)

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


return M
