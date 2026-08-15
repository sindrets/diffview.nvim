--[[
Partial staging: apply, unapply, or revert individual diff hunks - or just the
selected lines within them - directly from the diff windows.

This is the equivalent of VSCode's "Stage / Unstage / Revert Selected Ranges".
--]]

local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Unified = lazy.access("diffview.scene.layouts.unified", "Unified") ---@type Unified|LazyModule
local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local patch = lazy.require("diffview.vcs.patch") ---@module "diffview.vcs.patch"
local unified = lazy.require("diffview.vcs.unified") ---@module "diffview.vcs.unified"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local fmt = string.format

local M = {}

---@class diffview.staging.Op
---@field kind "stage"|"unstage"|"restore"
---@field range? { [1]: integer, [2]: integer } # A line range in the focused window.

---Find the window of the current layout that holds the cursor, and figure out
---which side of the diff it shows.
---@param view DiffView
---@return Window?
---@return "old"|"new"?
local function cur_diff_win(view)
  local curwin = api.nvim_get_current_win()
  local layout = view.cur_layout

  if not layout or not layout:is_valid() then return end

  for _, win in ipairs(layout.windows) do
    if win.id == curwin then
      -- In every 2-way layout the 'a' window holds the old version of the
      -- file, and 'b' holds the new. The 1-way and unified layouts only ever
      -- show the new side - the unified buffer addresses it through its line
      -- map.
      if layout:instanceof(Diff1.__get()) or layout:instanceof(Unified.__get()) then
        return win, "new"
      end

      return win, (layout.a and win.id == layout.a.id) and "old" or "new"
    end
  end
end

---The line map of the unified buffer, when that's what the cursor is in.
---@param view DiffView
---@param win Window
---@return unified.Data?
local function unified_data(view, win)
  if not view.cur_layout:instanceof(Unified.__get()) then return end
  return win.file and win.file.unified_data
end

---@param entry FileEntry
---@return integer? bufnr # The buffer holding the version that is being changed.
local function target_bufnr(entry)
  for _, win in ipairs(entry.layout.windows) do
    local file = win.file
    if file and file.rev and file.rev.type == RevType.LOCAL then return file.bufnr end
  end
end

---@param view DiffView
---@param entry FileEntry
---@param op diffview.staging.Op
---@return boolean ok
local function validate(view, entry, op)
  if not view.adapter:supports_partial_staging() then
    utils.err(fmt(
      "Partial staging is not supported by the '%s' adapter!",
      view.adapter.class:name()
    ))
    return false
  end

  if not (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL) then
    utils.err(
      "Hunks can only be staged from a diff between the index and the working tree. "
      .. "Try ':DiffviewOpen' without any revs."
    )
    return false
  end

  if entry.kind == "conflicting" then
    utils.err("This file has unresolved conflicts: resolve them before staging hunks.")
    return false
  end

  if op.kind == "stage" and entry.kind == "staged" then
    utils.info(fmt("'%s' is already staged.", entry.path))
    return false
  end

  if op.kind == "unstage" and entry.kind ~= "staged" then
    utils.info(fmt("There are no staged changes for '%s'.", entry.path))
    return false
  end

  if op.kind == "restore" and entry.kind == "staged" then
    utils.err(
      "Refusing to discard staged changes: unstage them first, "
      .. "or use the file panel to restore the whole file."
    )
    return false
  end

  for _, file in ipairs(entry.layout:files()) do
    local bufnr = file.bufnr

    if bufnr and api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      utils.err(fmt(
        "The buffer for '%s' has unsaved changes! Write it before staging hunks.",
        entry.path
      ))
      return false
    end
  end

  return true
end

---Get the patch for the given entry, creating an intent-to-add entry in the
---index for untracked files such that their content shows up as hunks.
---@param view DiffView
---@param entry FileEntry
---@param cached boolean
---@return patch.File?
local function get_patch(view, entry, cached)
  local lines = view.adapter:file_patch(entry.path, { cached = cached })
  local files = lines and patch.parse(lines) or {}

  if #files == 0 and not cached and entry.status == "?" then
    -- Untracked: record the file in the index without any content, so that git
    -- can produce a diff for it.
    local _, code = view.adapter:exec_sync(
      { "add", "--intent-to-add", "--", entry.path },
      view.adapter.ctx.toplevel
    )

    if code == 0 then
      lines = view.adapter:file_patch(entry.path, { cached = false })
      files = lines and patch.parse(lines) or {}
    end
  end

  return files[1]
end

---@param op diffview.staging.Op
---@param count integer
---@param entry FileEntry
---@return string
local function report(op, count, entry)
  local noun = count == 1 and "hunk" or "hunks"

  if op.range then
    noun = "selection" .. (count > 1 and (fmt(" (%d hunks)", count)) or "")
  end

  if op.kind == "stage" then
    return fmt("Staged %s in '%s'.", noun, entry.path)
  elseif op.kind == "unstage" then
    return fmt("Unstaged %s in '%s'.", noun, entry.path)
  end

  return fmt("Restored %s in '%s'.", noun, entry.path)
end

---Apply a hunk operation at the cursor.
---@param view DiffView
---@param op diffview.staging.Op
function M.apply(view, op)
  local win, side = cur_diff_win(view)

  if not win or not side then
    utils.err("The cursor must be in one of the diff windows to operate on a hunk.")
    return
  end

  local entry = view.panel.cur_file

  if not entry or entry:is_null_entry() then return end
  if not validate(view, entry, op) then return end

  -- `unstage` works on the index diff; everything else on the working tree diff.
  local cached = op.kind == "unstage"
  local file = get_patch(view, entry, cached)

  if not file or #file.hunks == 0 then
    utils.info(fmt("No %s changes in '%s'.", cached and "staged" or "unstaged", entry.path))
    return
  end

  -- Staging moves changes forward into the index. Unstaging and restoring both
  -- undo changes, and are applied in reverse.
  local reverse = op.kind ~= "stage"
  local hunks

  local data = unified_data(view, win)

  if op.range then
    local from, to = op.range[1], op.range[2]

    if data then
      -- Translate the selection in the unified buffer into a range on the new
      -- side of the diff.
      from, to = unified.to_new_range(data, from, to)

      if not from then
        utils.info("There are no changes in the selection.")
        return
      end
    end

    hunks = {}

    for _, hunk in ipairs(patch.hunks_in_range(file, from, to, side)) do
      local selection = patch.select_lines(hunk, from, to, side, reverse)
      if selection then hunks[#hunks + 1] = selection end
    end
  else
    local lnum = api.nvim_win_get_cursor(win.id)[1]

    if data then
      local line = data.map[lnum]

      if not line or line.kind == "gap" then
        utils.info("There is no hunk under the cursor.")
        return
      end

      lnum = line.new_lnum
    end

    -- A removed line at the end of a file sits just past the last line of the
    -- new side.
    local hunk = patch.hunk_at(file, lnum, side) or patch.hunk_at(file, lnum - 1, side)
    hunks = hunk and { hunk } or {}
  end

  if #hunks == 0 then
    utils.info(op.range
      and "There are no changes in the selection."
      or "There is no hunk under the cursor.")
    return
  end

  local ok, stderr = view.adapter:apply_patch(
    patch.build(file, hunks, reverse),
    { cached = op.kind ~= "restore", reverse = reverse }
  )

  if not ok then
    utils.err(utils.vec_join(
      fmt("Failed to %s the %s!", op.kind, op.range and "selection" or "hunk"),
      stderr
    ), true)
    return
  end

  if op.kind == "restore" then
    -- The file changed on disk: pull the new content into the buffer.
    local bufnr = target_bufnr(entry)
    if bufnr and api.nvim_buf_is_loaded(bufnr) then
      vim.cmd(fmt("checktime %d", bufnr))
    end
  end

  -- The unified buffer is derived from the diff: it has to be rebuilt.
  entry:refresh_unified()

  utils.info(report(op, #hunks, entry), true)

  view:update_files(vim.schedule_wrap(function()
    view.panel:highlight_cur_file()
  end))
  view.emitter:emit(EventName.FILES_STAGED, view)
end

---Resolve the line range to operate on. In visual mode this is the selection;
---otherwise the operation applies to the hunk under the cursor.
---@return { [1]: integer, [2]: integer }?
function M.get_range()
  local mode = api.nvim_get_mode().mode

  if not mode:match("^[vV\22]") then return end

  local from, to = vim.fn.line("."), vim.fn.line("v")
  if from > to then from, to = to, from end

  -- Leave visual mode: the operation reloads the buffers under the cursor.
  api.nvim_feedkeys(utils.t("<esc>"), "n", false)

  return { from, to }
end

return M
