--[[
Utilities for working with unified diff patches.

These are used to implement partial staging: a patch produced by the VCS is
parsed while retaining the raw patch lines, such that a new, valid patch can be
built from a subset of the hunks - or even a subset of the lines within a hunk.
The resulting patch can then be applied - possibly in reverse - to the index or
the working tree.
--]]

local M = {}

local HUNK_HEADER = [[^@@+ %-(%d+),?(%d*) %+(%d+),?(%d*) @@]]
local NO_NEWLINE = "\\"

---A single hunk from a unified diff patch.
---@class patch.Hunk
---@field old_row integer # First line of the hunk on the old side.
---@field old_size integer # Number of lines the hunk spans on the old side.
---@field new_row integer # First line of the hunk on the new side.
---@field new_size integer # Number of lines the hunk spans on the new side.
---@field lines string[] # The raw body lines of the hunk, signs included.
---@field index integer # The index of the hunk in its file.

---A single file section from a unified diff patch.
---@class patch.File
---@field header string[] # The raw header lines, up to (not including) the first hunk.
---@field path_old string?
---@field path_new string?
---@field hunks patch.Hunk[]

---@param line string
---@return integer? old_row
---@return integer? old_size
---@return integer? new_row
---@return integer? new_size
local function parse_hunk_header(line)
  local old_row, old_size, new_row, new_size = line:match(HUNK_HEADER)
  if not old_row then return end

  return tonumber(old_row),
    old_size == "" and 1 or tonumber(old_size),
    tonumber(new_row),
    new_size == "" and 1 or tonumber(new_size)
end

---Parse the output of a `diff` command into its file sections and hunks. The
---raw patch lines are retained such that a new patch can be built from any
---subset of the parsed content.
---@param lines string[]
---@return patch.File[]
function M.parse(lines)
  local files = {} ---@type patch.File[]
  local cur_file ---@type patch.File?
  local cur_hunk ---@type patch.Hunk?
  local old_left, new_left = 0, 0

  for _, line in ipairs(lines) do
    if line:match("^diff ") then
      cur_file = { header = { line }, hunks = {} }
      cur_hunk = nil
      files[#files + 1] = cur_file

    elseif cur_file then
      local old_row, old_size, new_row, new_size = parse_hunk_header(line)

      if old_row then
        cur_hunk = {
          old_row = old_row,
          old_size = old_size,
          new_row = new_row,
          new_size = new_size,
          lines = {},
          index = #cur_file.hunks + 1,
        }
        old_left, new_left = old_size, new_size
        cur_file.hunks[#cur_file.hunks + 1] = cur_hunk

      elseif cur_hunk and (old_left > 0 or new_left > 0 or line:sub(1, 1) == NO_NEWLINE) then
        -- Some diff producers emit a bare empty line for an empty context
        -- line. Normalize it such that the patch can be rebuilt verbatim.
        if line == "" then line = " " end
        local sign = line:sub(1, 1)

        if sign == " " then
          old_left, new_left = old_left - 1, new_left - 1
        elseif sign == "-" then
          old_left = old_left - 1
        elseif sign == "+" then
          new_left = new_left - 1
        elseif sign ~= NO_NEWLINE then
          -- Not part of the hunk body: the hunk ends here.
          cur_hunk = nil
          goto continue
        end

        cur_hunk.lines[#cur_hunk.lines + 1] = line

      elseif not cur_hunk then
        cur_file.header[#cur_file.header + 1] = line

        local path_old = line:match("^%-%-%- a/(.*)") or line:match("^%-%-%- (/dev/null)")
        if path_old then cur_file.path_old = path_old ~= "/dev/null" and path_old or nil end

        local path_new = line:match("^%+%+%+ b/(.*)") or line:match("^%+%+%+ (/dev/null)")
        if path_new then cur_file.path_new = path_new ~= "/dev/null" and path_new or nil end
      end
    end

    ::continue::
  end

  return files
end

---@param hunk patch.Hunk
---@param side "old"|"new"
---@return integer first
---@return integer last
local function hunk_range(hunk, side)
  local row = side == "old" and hunk.old_row or hunk.new_row
  local size = side == "old" and hunk.old_size or hunk.new_size

  if size == 0 then
    -- The hunk doesn't exist on this side: it lies between `row` and `row + 1`.
    return row, row + 1
  end

  return row, row + size - 1
end

---Get the hunk that covers the given line number on the given side of the diff.
---@param file patch.File
---@param lnum integer
---@param side "old"|"new"
---@return patch.Hunk?
function M.hunk_at(file, lnum, side)
  for _, hunk in ipairs(file.hunks) do
    local first, last = hunk_range(hunk, side)
    if lnum >= first and lnum <= last then return hunk end
  end
end

---Get all the hunks that intersect the given line range on the given side of
---the diff.
---@param file patch.File
---@param from integer
---@param to integer
---@param side "old"|"new"
---@return patch.Hunk[]
function M.hunks_in_range(file, from, to, side)
  local ret = {}

  for _, hunk in ipairs(file.hunks) do
    local first, last = hunk_range(hunk, side)
    if first <= to and last >= from then ret[#ret + 1] = hunk end
  end

  return ret
end

---Get the hunk that follows / precedes the given line number on the given side
---of the diff.
---@param file patch.File
---@param lnum integer
---@param side "old"|"new"
---@param dir -1|1
---@return patch.Hunk?
function M.adjacent_hunk(file, lnum, side, dir)
  local ret

  for _, hunk in ipairs(file.hunks) do
    local first, last = hunk_range(hunk, side)

    if dir > 0 and first > lnum then
      return hunk
    elseif dir < 0 and last < lnum then
      ret = hunk
    end
  end

  return dir < 0 and ret or nil
end

---@param from integer
---@param to integer
---@param lnum integer
---@return boolean
local function in_range(from, to, lnum)
  return lnum >= from and lnum <= to
end

---@class patch.Line
---@field sign string
---@field text string
---@field old_lnum? integer
---@field new_lnum? integer
---@field anchor? integer # The line number on the opposite side that this line is paired with.
---@field marker? string # A trailing "\ No newline at end of file" marker.

---@class patch.Block
---@field dels patch.Line[]
---@field adds patch.Line[]

---Split the body of a hunk into its individual lines, with the line numbers
---they occupy on either side of the diff.
---
---Consecutive changed lines form a block. Within a block the n-th deletion is
---considered a modification of the n-th addition, which is what makes it
---possible to pick a single line out of a block of changes. Any surplus
---deletion is paired with the last addition in its block (and vice versa).
---@param hunk patch.Hunk
---@return patch.Line[] lines
---@return patch.Block[] blocks
local function decompose(hunk)
  local lines, blocks = {}, {}
  local old_lnum, new_lnum = hunk.old_row, hunk.new_row
  local block

  local function close_block()
    if not block then return end

    for i, line in ipairs(block.dels) do
      if #block.adds > 0 then
        line.anchor = block.adds[math.min(i, #block.adds)].new_lnum
      end
    end

    for i, line in ipairs(block.adds) do
      if #block.dels > 0 then
        line.anchor = block.dels[math.min(i, #block.dels)].old_lnum
      end
    end

    block = nil
  end

  for _, text in ipairs(hunk.lines) do
    local sign = text:sub(1, 1)

    if sign == NO_NEWLINE then
      -- The marker belongs to the line that precedes it.
      if lines[#lines] then lines[#lines].marker = text end

    elseif sign == " " then
      close_block()
      lines[#lines + 1] = {
        sign = sign,
        text = text,
        old_lnum = old_lnum,
        new_lnum = new_lnum,
      }
      old_lnum, new_lnum = old_lnum + 1, new_lnum + 1

    else
      if not block then
        block = { dels = {}, adds = {} }
        blocks[#blocks + 1] = block
      end

      local line = {
        sign = sign,
        text = text,
        old_lnum = old_lnum,
        new_lnum = new_lnum,
      }
      lines[#lines + 1] = line

      if sign == "-" then
        block.dels[#block.dels + 1] = line
        old_lnum = old_lnum + 1
      else
        block.adds[#block.adds + 1] = line
        new_lnum = new_lnum + 1
      end
    end
  end

  close_block()

  return lines, blocks
end

---@param line patch.Line
---@param from integer
---@param to integer
---@param side "old"|"new"
---@return boolean
local function is_selected(line, from, to, side)
  local own = side == "old" and line.old_lnum or line.new_lnum

  if (side == "old") == (line.sign == "-") then
    -- The line exists on the side the selection was made on.
    return in_range(from, to, own)
  end

  if line.anchor then
    -- Select the line together with the line it modifies.
    return in_range(from, to, line.anchor)
  end

  -- The line has no counterpart: it sits between two lines on the other side.
  return in_range(from, to, own) or in_range(from, to, own - 1)
end

---Create a new hunk from the subset of `hunk` that lies within the given line
---range on the given side of the diff.
---
---Lines that are *not* selected are neutralized: for a patch that is going to
---be applied in the forward direction, unselected additions are dropped, and
---unselected deletions are demoted to context lines. When the patch is applied
---in reverse, the roles are inverted.
---@param hunk patch.Hunk
---@param from integer
---@param to integer
---@param side "old"|"new" # The side of the diff that the range refers to.
---@param reverse boolean # The resulting patch will be applied in reverse.
---@return patch.Hunk? # `nil` if the selection doesn't cover any changed line.
function M.select_lines(hunk, from, to, side, reverse)
  local decomposed, blocks = decompose(hunk)
  local out = {}
  local old_row, new_row = hunk.old_row, hunk.new_row
  local old_size, new_size = 0, 0
  local changed = false

  ---@param line patch.Line
  ---@param sign string
  local function emit(line, sign)
    out[#out + 1] = sign .. line.text:sub(2)
    if line.marker then out[#out + 1] = line.marker end

    if sign ~= "+" then old_size = old_size + 1 end
    if sign ~= "-" then new_size = new_size + 1 end
  end

  ---Emit a deletion / addition pair. The two lines of a pair are always
  ---selected together, so that the changed line keeps its place in both
  ---versions of the file.
  ---@param del? patch.Line
  ---@param add? patch.Line
  local function emit_pair(del, add)
    local selected = (del and is_selected(del, from, to, side))
      or (add and is_selected(add, from, to, side))
      or false

    if selected then
      changed = true
      if del then emit(del, "-") end
      if add then emit(add, "+") end
      return
    end

    -- Unselected: keep the version that the patch is applied against, so that
    -- the change is left exactly as it is.
    if reverse then
      if add then emit(add, " ") end
    else
      if del then emit(del, " ") end
    end
  end

  local block_idx, i = 1, 1

  while i <= #decomposed do
    local line = decomposed[i]

    if line.sign == " " then
      emit(line, " ")
      i = i + 1
    else
      local block = blocks[block_idx]
      block_idx = block_idx + 1

      for j = 1, math.max(#block.dels, #block.adds) do
        emit_pair(block.dels[j], block.adds[j])
      end

      i = i + #block.dels + #block.adds
    end
  end

  if not changed then return end

  -- An empty side is addressed by the line it follows.
  if old_size == 0 and hunk.old_size > 0 then old_row = math.max(old_row - 1, 0) end
  if new_size == 0 and hunk.new_size > 0 then new_row = math.max(new_row - 1, 0) end

  return {
    old_row = old_row,
    old_size = old_size,
    new_row = new_row,
    new_size = new_size,
    lines = out,
    index = hunk.index,
  }
end

---Build a patch that can be fed to `git apply` from a file section and a
---subset of its hunks.
---
---The line numbers on the target side of the patch are recalculated such that
---the hunk offsets stay consistent when only some of the file's hunks are
---included.
---@param file patch.File
---@param hunks patch.Hunk[]
---@param reverse? boolean # The patch is going to be applied in reverse.
---@return string
function M.build(file, hunks, reverse)
  local out = {}

  for _, line in ipairs(file.header) do
    out[#out + 1] = line
  end

  local offset = 0

  for _, hunk in ipairs(hunks) do
    local old_row, new_row = hunk.old_row, hunk.new_row

    if reverse then
      -- The new side is the source: keep it, derive the old side.
      old_row = math.max(hunk.new_row + offset, hunk.old_size == 0 and 0 or 1)
      offset = offset + (hunk.old_size - hunk.new_size)
    else
      new_row = math.max(hunk.old_row + offset, hunk.new_size == 0 and 0 or 1)
      offset = offset + (hunk.new_size - hunk.old_size)
    end

    out[#out + 1] = ("@@ -%d,%d +%d,%d @@"):format(old_row, hunk.old_size, new_row, hunk.new_size)

    for _, line in ipairs(hunk.lines) do
      out[#out + 1] = line
    end
  end

  return table.concat(out, "\n") .. "\n"
end

---Count the number of added and removed lines in a set of hunks.
---@param hunks patch.Hunk[]
---@return integer additions
---@return integer deletions
function M.count_changes(hunks)
  local additions, deletions = 0, 0

  for _, hunk in ipairs(hunks) do
    for _, line in ipairs(hunk.lines) do
      local sign = line:sub(1, 1)
      if sign == "+" then
        additions = additions + 1
      elseif sign == "-" then
        deletions = deletions + 1
      end
    end
  end

  return additions, deletions
end

return M
