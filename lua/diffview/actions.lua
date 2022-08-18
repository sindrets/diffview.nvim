local lazy = require("diffview.lazy")

---@type DiffView|LazyModule
local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView")
---@type FileHistoryView|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView")
---@type StandardView|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView")
---@module "diffview.lib"
local lib = lazy.require("diffview.lib")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local api = vim.api

local M = setmetatable({}, {
  __index = function(_, k)
    utils.err((
      "The action '%s' does not exist! "
      .. "See ':h diffview-available-actions' for an overview of available actions."
    ):format(k))
  end
})

---@return FileEntry?
---@return integer[]? cursor
local function prepare_goto_file()
  local view = lib.get_current_view()

  if view and not (view:instanceof(DiffView.__get()) or view:instanceof(FileHistoryView.__get())) then
    return
  end

  ---@cast view DiffView|FileHistoryView

  local file = view:infer_cur_file()
  if file then
    ---@cast file FileEntry
    -- Ensure file exists
    if not utils.path:readable(file.absolute_path) then
      utils.err(
        string.format(
          "File does not exist on disk: '%s'",
          utils.path:relative(file.absolute_path, ".")
        )
      )
      return
    end

    local cursor
    local cur_file = (view.panel.cur_item and view.panel.cur_item[2]) or view.panel.cur_file
    if file == cur_file then
      local win = view.cur_layout:get_main_win()
      cursor = api.nvim_win_get_cursor(win.id)
    end

    return file, cursor
  end
end

function M.goto_file()
  local file, cursor = prepare_goto_file()

  if file then
    local target_tab = lib.get_prev_non_view_tabpage()

    if target_tab then
      api.nvim_set_current_tabpage(target_tab)
      vim.cmd("sp " .. vim.fn.fnameescape(file.absolute_path))
    else
      vim.cmd("tabe " .. vim.fn.fnameescape(file.absolute_path))
    end

    vim.cmd("diffoff")

    if cursor then
      -- NOTE: using normal command rather than `nvim_win_set_cursor` to avoid
      -- dealing with out-of-bounds coordinates.
      vim.cmd(("norm! %dG"):format(cursor[1]))
    end
  end
end

function M.goto_file_edit()
  local file, cursor = prepare_goto_file()

  if file then
    local target_tab = lib.get_prev_non_view_tabpage()

    if target_tab then
      api.nvim_set_current_tabpage(target_tab)
      vim.cmd("e " .. vim.fn.fnameescape(file.absolute_path))
    else
      vim.cmd("tabe " .. vim.fn.fnameescape(file.absolute_path))
    end

    vim.cmd("diffoff")

    if cursor then
      vim.cmd(("norm! %dG"):format(cursor[1]))
    end
  end
end

function M.goto_file_split()
  local file, cursor = prepare_goto_file()

  if file then
    vim.cmd("sp " .. vim.fn.fnameescape(file.absolute_path))
    vim.cmd("diffoff")

    if cursor then
      vim.cmd(("norm! %dG"):format(cursor[1]))
    end
  end
end

function M.goto_file_tab()
  local file, cursor = prepare_goto_file()

  if file then
    vim.cmd("tabe " .. vim.fn.fnameescape(file.absolute_path))
    vim.cmd("diffoff")

    if cursor then
      vim.cmd(("norm! %dG"):format(cursor[1]))
    end
  end
end

---Execute `cmd` for each target window in the current view. If no targets
---are given, all windows are targeted.
---@param cmd string|function The vim cmd to execute, or a function.
---@param targets? { a: boolean, b: boolean, c: boolean, d: boolean } The windows to target.
---@return function action
function M.view_windo(cmd, targets)
  local fun

  if type(cmd) == "string" then
    fun = function() vim.cmd(cmd) end
  else
    fun = cmd
  end

  return function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      targets = targets or { a = true, b = true, c = true, d = true }

      for _, symbol in ipairs({ "a", "b", "c", "d" }) do
        local win = view.cur_layout[symbol] --[[@as Window? ]]

        if targets[symbol] and win then
          api.nvim_win_call(win.id, fun)
        end
      end
    end
  end
end

---@param distance number Either an exact number of lines, or a fraction of the window height.
---@return function
function M.scroll_view(distance)
  local scroll_opr = distance < 0 and [[\<c-y>]] or [[\<c-e>]]
  local scroll_cmd

  if distance % 1 == 0 then
    scroll_cmd = ([[exe "norm! %d%s"]]):format(distance, scroll_opr)
  else
    scroll_cmd = ([[exe "norm! " . float2nr(winheight(0) * %f) . "%s"]])
        :format(distance, scroll_opr)
  end

  return function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      local max = -1
      local target

      for _, win in ipairs(view.cur_layout.windows) do
        local c = api.nvim_buf_line_count(api.nvim_win_get_buf(win.id))
        if c > max then
          max = c
          target = win.id
        end
      end

      if target then
        api.nvim_win_call(target, function()
          vim.cmd(scroll_cmd)
        end)
      end
    end
  end
end

local action_names = {
  "close",
  "close_all_folds",
  "copy_hash",
  "focus_entry",
  "focus_files",
  "listing_style",
  "next_entry",
  "open_all_folds",
  "open_commit_log",
  "open_in_diffview",
  "options",
  "prev_entry",
  "refresh_files",
  "restore_entry",
  "select_entry",
  "select_next_entry",
  "select_prev_entry",
  "stage_all",
  "toggle_files",
  "toggle_flatten_dirs",
  "toggle_stage_entry",
  "unstage_all",
}

for _, name in ipairs(action_names) do
  M[name] = function()
    require("diffview").emit(name)
  end
end

return M
