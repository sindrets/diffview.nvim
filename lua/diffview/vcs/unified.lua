--[[
The content of the unified ("inline") diff view.

Rather than a classic patch - where every line carries a `+`/`-` prefix and the
whole buffer is highlighted as a diff - this renders the file the way it looks
after the change, with the removed lines spliced back in at their old
positions. Added and removed lines get a line highlight, and the parts of a
line that actually changed get a stronger one. That keeps the buffer close
enough to the real file that syntax highlighting still works, which is what
makes the inline diff readable.
--]]

local lazy = require("diffview.lazy")

local patch = lazy.require("diffview.vcs.patch") ---@module "diffview.vcs.patch"

local api = vim.api

local M = {}

---Enough context to cover any sane file in a single hunk.
local CONTEXT_ALL = 1000000

---Number of unchanged lines kept visible around a change.
local FOLD_PADDING = 3

M.ns = api.nvim_create_namespace("diffview_unified")

---Deletions live in their own namespace: the marks track where the removed
---lines are as the buffer is edited, which is what makes it possible to write
---the buffer back without them.
M.ns_del = api.nvim_create_namespace("diffview_unified_del")

---A single line of the unified buffer.
---@class unified.Line
---@field kind "context"|"add"|"del"|"gap"
---@field old_lnum integer # The line number on the old side.
---@field new_lnum integer # The line number on the new side. For a removed line: the line it precedes.

---@class unified.TextRange
---@field line integer # 1-based line in the unified buffer.
---@field col_start integer # 0-based byte column.
---@field col_end integer

---@class unified.Data
---@field lines string[] # The buffer content.
---@field map unified.Line[] # One entry per line of `lines`.
---@field folds { [1]: integer, [2]: integer }[] # The unchanged regions.
---@field blocks { [1]: integer, [2]: integer }[] # The changed regions.
---@field text_ranges unified.TextRange[] # The changed parts within a changed line.
---@field additions integer
---@field deletions integer
---@field has_gap boolean # True when the diff was too large to render in full.

---Find the parts of two versions of a line that actually differ, by trimming
---the common prefix and suffix.
---@param old string
---@param new string
---@return integer? old_start
---@return integer? old_end
---@return integer? new_start
---@return integer? new_end
local function inner_change(old, new)
  if old == new then return end

  local max_prefix = math.min(#old, #new)
  local prefix = 0

  while prefix < max_prefix and old:byte(prefix + 1) == new:byte(prefix + 1) do
    prefix = prefix + 1
  end

  local max_suffix = math.min(#old, #new) - prefix
  local suffix = 0

  while suffix < max_suffix and old:byte(#old - suffix) == new:byte(#new - suffix) do
    suffix = suffix + 1
  end

  -- Don't bother when the lines have nothing in common: the line highlight
  -- already says everything there is to say.
  if prefix == 0 and suffix == 0 then return end

  return prefix, #old - suffix, prefix, #new - suffix
end

---@param data unified.Data
---@param first integer # First line of a changed block.
---@param last integer
local function mark_inner_changes(data, first, last)
  local dels, adds = {}, {}

  for i = first, last do
    local kind = data.map[i].kind
    if kind == "del" then
      dels[#dels + 1] = i
    elseif kind == "add" then
      adds[#adds + 1] = i
    end
  end

  -- The n-th removed line is considered a modification of the n-th added one:
  -- the same pairing that partial staging uses.
  for i = 1, math.min(#dels, #adds) do
    local old_line, new_line = data.lines[dels[i]], data.lines[adds[i]]
    local os, oe, ns, ne = inner_change(old_line, new_line)

    if os then
      if oe > os then
        data.text_ranges[#data.text_ranges + 1] = { line = dels[i], col_start = os, col_end = oe }
      end

      if ne > ns then
        data.text_ranges[#data.text_ranges + 1] = { line = adds[i], col_start = ns, col_end = ne }
      end
    end
  end
end

---Collect the changed and unchanged regions, and the within-line changes.
---@param data unified.Data
local function analyze(data)
  local i, n = 1, #data.map

  while i <= n do
    local kind = data.map[i].kind

    if kind == "context" then
      local first = i
      while i <= n and data.map[i].kind == "context" do i = i + 1 end
      local last = i - 1

      -- Fold the middle of a long unchanged stretch, keeping a few lines
      -- visible on either side of the neighbouring changes.
      local fold_first = first + (first > 1 and FOLD_PADDING or 0)
      local fold_last = last - (last < n and FOLD_PADDING or 0)

      if fold_last - fold_first >= 1 then
        data.folds[#data.folds + 1] = { fold_first, fold_last }
      end
    elseif kind == "gap" then
      i = i + 1
    else
      local first = i
      while i <= n and (data.map[i].kind == "add" or data.map[i].kind == "del") do i = i + 1 end
      local last = i - 1

      data.blocks[#data.blocks + 1] = { first, last }
      mark_inner_changes(data, first, last)
    end
  end
end

---Build the content of the unified diff for a single file.
---@param adapter VCSAdapter
---@param path string
---@param opt { cached?: boolean, untracked?: boolean, absolute_path?: string }
---@return unified.Data?
function M.build(adapter, path, opt)
  opt = opt or {}

  ---@type unified.Data
  local data = {
    lines = {},
    map = {},
    folds = {},
    blocks = {},
    text_ranges = {},
    additions = 0,
    deletions = 0,
    has_gap = false,
  }

  local raw = adapter:file_patch(path, { cached = opt.cached, context = CONTEXT_ALL })
  local file = (raw and patch.parse(raw) or {})[1]

  if not file or #file.hunks == 0 then
    -- An untracked file has no diff: show all of it as added.
    if opt.untracked and opt.absolute_path and vim.fn.filereadable(opt.absolute_path) == 1 then
      local content = vim.fn.readfile(opt.absolute_path)

      for i, line in ipairs(content) do
        data.lines[i] = line
        data.map[i] = { kind = "add", old_lnum = 1, new_lnum = i }
      end

      data.additions = #content
      analyze(data)

      return data
    end

    return
  end

  local prev_hunk_end

  for _, hunk in ipairs(file.hunks) do
    -- With full context there is only ever one hunk. If a file is large enough
    -- to be split anyway, mark the omitted region rather than silently
    -- dropping it.
    if prev_hunk_end and hunk.new_row > prev_hunk_end + 1 then
      data.lines[#data.lines + 1] = ("⋯ %d lines"):format(hunk.new_row - prev_hunk_end - 1)
      data.map[#data.map + 1] = { kind = "gap", old_lnum = hunk.old_row, new_lnum = hunk.new_row }
      data.has_gap = true
    end

    local old_lnum, new_lnum = hunk.old_row, hunk.new_row

    for _, text in ipairs(hunk.lines) do
      local sign, content = text:sub(1, 1), text:sub(2)

      if sign == " " then
        data.lines[#data.lines + 1] = content
        data.map[#data.map + 1] = { kind = "context", old_lnum = old_lnum, new_lnum = new_lnum }
        old_lnum, new_lnum = old_lnum + 1, new_lnum + 1

      elseif sign == "-" then
        data.lines[#data.lines + 1] = content
        data.map[#data.map + 1] = { kind = "del", old_lnum = old_lnum, new_lnum = new_lnum }
        data.deletions = data.deletions + 1
        old_lnum = old_lnum + 1

      elseif sign == "+" then
        data.lines[#data.lines + 1] = content
        data.map[#data.map + 1] = { kind = "add", old_lnum = old_lnum, new_lnum = new_lnum }
        data.additions = data.additions + 1
        new_lnum = new_lnum + 1
      end
    end

    prev_hunk_end = hunk.new_row + hunk.new_size - 1
  end

  analyze(data)

  return data
end

---@param bufnr integer
---@param data unified.Data
function M.apply_highlights(bufnr, data)
  if not api.nvim_buf_is_valid(bufnr) then return end

  api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, M.ns_del, 0, -1)

  for i, line in ipairs(data.map) do
    local hl, sign

    if line.kind == "add" then
      hl, sign = "DiffviewDiffAdd", "+"
    elseif line.kind == "del" then
      hl, sign = "DiffviewDiffDelete", "-"
    elseif line.kind == "gap" then
      hl = "DiffviewNonText"
    end

    if hl then
      local ns = line.kind == "del" and M.ns_del or M.ns
      local opts = { line_hl_group = hl }

      if sign then
        opts.sign_text = sign
        opts.sign_hl_group = hl
      end

      -- `sign_text` isn't available on every supported version.
      if not pcall(api.nvim_buf_set_extmark, bufnr, ns, i - 1, 0, opts) then
        opts.sign_text, opts.sign_hl_group = nil, nil
        pcall(api.nvim_buf_set_extmark, bufnr, ns, i - 1, 0, opts)
      end
    end
  end

  for _, range in ipairs(data.text_ranges) do
    pcall(api.nvim_buf_set_extmark, bufnr, M.ns, range.line - 1, range.col_start, {
      end_col = range.col_end,
      hl_group = "DiffviewDiffText",
      priority = 200,
    })
  end
end

---The content of the new side of the diff, as it currently stands in the
---buffer.
---
---The removed lines are tracked by extmarks, so they follow along as the
---buffer is edited: whatever is left after dropping them is the file.
---@param bufnr integer
---@return string[]
function M.new_side_content(bufnr)
  local removed = {}

  for _, mark in ipairs(api.nvim_buf_get_extmarks(bufnr, M.ns_del, 0, -1, {})) do
    removed[mark[2] + 1] = true
  end

  local ret = {}

  for i, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not removed[i] then ret[#ret + 1] = line end
  end

  return ret
end

---Translate a line range in the unified buffer into a line range on the new
---side of the diff, which is what the staging functions work with.
---@param data unified.Data
---@param from integer
---@param to integer
---@return integer? new_from
---@return integer? new_to
function M.to_new_range(data, from, to)
  local first, last

  for i = math.max(from, 1), math.min(to, #data.map) do
    local line = data.map[i]

    if line.kind ~= "gap" then
      first = math.min(first or line.new_lnum, line.new_lnum)
      last = math.max(last or line.new_lnum, line.new_lnum)
    end
  end

  return first, last
end

---The next / previous changed region, relative to a line in the unified
---buffer.
---@param data unified.Data
---@param lnum integer
---@param dir -1|1
---@return integer? lnum
function M.adjacent_change(data, lnum, dir)
  local ret

  for _, block in ipairs(data.blocks) do
    if dir > 0 and block[1] > lnum then
      return block[1]
    elseif dir < 0 then
      -- Like `[c`: from inside a change, jump to the start of it first.
      if lnum > block[1] and lnum <= block[2] then return block[1] end
      if block[2] < lnum then ret = block[1] end
    end
  end

  return dir < 0 and ret or nil
end

---The first / last changed region.
---@param data unified.Data
---@param dir -1|1
---@return integer? lnum
function M.edge_change(data, dir)
  local block = dir > 0 and data.blocks[1] or data.blocks[#data.blocks]
  return block and block[1] or nil
end

---@param data unified.Data
---@param lnum integer
---@return boolean
function M.is_change(data, lnum)
  local line = data.map[lnum]
  return line ~= nil and (line.kind == "add" or line.kind == "del")
end

return M
