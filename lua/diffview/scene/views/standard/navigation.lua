--[[
Navigation between the individual changes of a view.

Vim's built-in `]c` / `[c` motions stop at the boundaries of the current file.
These jump to the next / previous change in the view as a whole, rolling over
into the next / previous file entry - the way `F7` / `Shift+F7` does in VSCode.
--]]

local lazy = require("diffview.lazy")

local unified = lazy.require("diffview.vcs.unified") ---@module "diffview.vcs.unified"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

local M = {}

---@param view StandardView
---@param dir -1|1
---@return FileEntry?
local function step_entry(view, dir)
  -- NOTE: `next_file()` returns nil when there is no other entry to move to,
  -- so these can't be folded into an `and`/`or` chain: that would call the
  -- method of the *other* view type as a fallback.
  if view.next_file then
    ---@cast view DiffView
    if dir > 0 then return view:next_file(true) end
    return view:prev_file(true)
  end

  ---@cast view FileHistoryView
  if dir > 0 then return view:next_item() end
  return view:prev_item()
end

---@param winid integer
---@param lnum integer
---@return boolean
local function is_change(winid, lnum)
  return api.nvim_win_call(winid, function()
    return vim.fn.diff_hlID(lnum, 1) > 0
  end)
end

---The line map of the window's buffer, if it's showing a unified diff.
---@param win Window
---@return unified.Data?
local function unified_data(win)
  return win and win.file and win.file.unified_data or nil
end

---Move the cursor to the next / previous change within a single window.
---@param win Window
---@param dir -1|1
---@param count? integer
---@return boolean moved
local function jump_change(win, dir, count)
  local data = unified_data(win)

  if data then
    -- The unified buffer isn't in diff mode: walk the changed regions.
    local lnum = api.nvim_win_get_cursor(win.id)[1]
    local moved = false

    for _ = 1, count or 1 do
      local next_lnum = unified.adjacent_change(data, lnum, dir)
      if not next_lnum then break end
      lnum, moved = next_lnum, true
    end

    if moved then
      utils.set_cursor(win.id, lnum, 0)
      api.nvim_win_call(win.id, function() vim.cmd("norm! zv") end)
    end

    return moved
  end

  local moved = false

  api.nvim_win_call(win.id, function()
    if not vim.wo.diff then return end

    local before = api.nvim_win_get_cursor(win.id)[1]
    pcall(vim.cmd, ("keepjumps normal! %d%s"):format(count or 1, dir > 0 and "]c" or "[c"))
    moved = api.nvim_win_get_cursor(win.id)[1] ~= before
  end)

  return moved
end

---Place the cursor on the first / last change of the current file.
---@param view StandardView
---@param dir -1|1
local function goto_edge_change(view, dir)
  if not (view.cur_layout and view.cur_layout:is_valid()) then return end

  local win = view.cur_layout:get_main_win()
  local data = unified_data(win)

  if data then
    local lnum = unified.edge_change(data, dir)

    if lnum then
      utils.set_cursor(win.id, lnum, 0)
      api.nvim_win_call(win.id, function() vim.cmd("norm! zv") end)
    end
  else
    local lnum = dir > 0 and 1 or api.nvim_buf_line_count(win.file.bufnr)

    utils.set_cursor(win.id, lnum, 0)

    if not is_change(win.id, lnum) then
      jump_change(win, dir)
    end
  end

  api.nvim_win_call(win.id, function() vim.cmd("norm! zz") end)
  view.cur_layout:sync_scroll()
end

---Jump to the next / previous change in the view. Rolls over into the next /
---previous file entry when there are no more changes in the current file.
---@param view StandardView
---@param dir -1|1
function M.goto_change(view, dir)
  if not (view.cur_layout and view.cur_layout:is_valid()) then return end

  local curwin = api.nvim_get_current_win()
  local target = view.cur_layout:get_main_win()

  for _, win in ipairs(view.cur_layout.windows) do
    if win.id == curwin then
      target = win
      break
    end
  end

  if jump_change(target, dir, vim.v.count1) then
    api.nvim_win_call(target.id, function() vim.cmd("norm! zz") end)
    if curwin ~= target.id then view.cur_layout:sync_scroll() end
    return
  end

  -- No more changes in this file: continue in the next one.
  local on_open = function()
    -- Deferred: entries that are opened for the first time have their cursor
    -- reset once the buffers are attached.
    vim.schedule(function() goto_edge_change(view, dir) end)
  end

  view.emitter:once("file_open_post", on_open)

  if not step_entry(view, dir) then
    view.emitter:off(on_open, "file_open_post")
    utils.info("There are no more changes.")
  end
end

return M
