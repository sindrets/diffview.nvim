local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local git = lazy.require("diffview.git.utils") ---@module "diffview.git.utils"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") ---@type Diff2Hor|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") ---@type Diff2Ver|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver") ---@type Diff3Hor|LazyModule
local Diff3Mixed = lazy.access("diffview.scene.layouts.diff_3_mixed", "Diff3Mixed") ---@type Diff3Mixed|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule

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
    local cur_file = view.cur_entry
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
      file.layout:restore_winopts()
      vim.cmd("sp " .. vim.fn.fnameescape(file.absolute_path))
    else
      vim.cmd("tabnew")
      local temp_bufnr = api.nvim_get_current_buf()
      file.layout:restore_winopts()
      vim.cmd("keepalt edit " .. vim.fn.fnameescape(file.absolute_path))

      if temp_bufnr ~= api.nvim_get_current_buf() then
        api.nvim_buf_delete(temp_bufnr, { force = true })
      end
    end

    if cursor then
      utils.set_cursor(0, unpack(cursor))
    end
  end
end

function M.goto_file_edit()
  local file, cursor = prepare_goto_file()

  if file then
    local target_tab = lib.get_prev_non_view_tabpage()

    if target_tab then
      api.nvim_set_current_tabpage(target_tab)
      file.layout:restore_winopts()
      vim.cmd("edit " .. vim.fn.fnameescape(file.absolute_path))
    else
      vim.cmd("tabnew")
      local temp_bufnr = api.nvim_get_current_buf()
      file.layout:restore_winopts()
      vim.cmd("keepalt edit " .. vim.fn.fnameescape(file.absolute_path))

      if temp_bufnr ~= api.nvim_get_current_buf() then
        api.nvim_buf_delete(temp_bufnr, { force = true })
      end
    end

    if cursor then
      utils.set_cursor(0, unpack(cursor))
    end
  end
end

function M.goto_file_split()
  local file, cursor = prepare_goto_file()

  if file then
    vim.cmd("new")
    local temp_bufnr = api.nvim_get_current_buf()
    file.layout:restore_winopts()
    vim.cmd("keepalt edit " .. vim.fn.fnameescape(file.absolute_path))

    if temp_bufnr ~= api.nvim_get_current_buf() then
      api.nvim_buf_delete(temp_bufnr, { force = true })
    end

    if cursor then
      utils.set_cursor(0, unpack(cursor))
    end
  end
end

function M.goto_file_tab()
  local file, cursor = prepare_goto_file()

  if file then
    vim.cmd("tabnew")
    local temp_bufnr = api.nvim_get_current_buf()
    file.layout:restore_winopts()
    vim.cmd("keepalt edit " .. vim.fn.fnameescape(file.absolute_path))

    if temp_bufnr ~= api.nvim_get_current_buf() then
      api.nvim_buf_delete(temp_bufnr, { force = true })
    end

    if cursor then
      utils.set_cursor(0, unpack(cursor))
    end
  end
end

---Jump to the next merge conflict marker.
function M.next_conflict()
  local view = lib.get_current_view()

  if view and view:instanceof(StandardView.__get()) then
    ---@cast view StandardView
    local main = view.cur_layout:get_main_win()
    local curfile = main.file

    if main:is_valid() and curfile:is_valid() then
      local conflicts, cur = git.parse_conflicts(
        api.nvim_buf_get_lines(curfile.bufnr, 0, -1, false),
        main.id
      )

      if #conflicts > 0 then
        local cur_idx = utils.vec_indexof(conflicts, cur)
        local next_idx = (cur_idx == -1) and 1 or cur_idx % #conflicts + 1
        local next_conflict = conflicts[next_idx]
        local curwin = api.nvim_get_current_win()

        api.nvim_win_call(main.id, function()
          api.nvim_win_set_cursor(main.id, { next_conflict.first, 0 })

          if curwin ~= main.id then
            -- HACK: Trigger sync for the scrollbind + cursorbind
            vim.cmd([[exe "norm! \<c-e>\<c-y>"]])
          end
        end)

        api.nvim_echo({{ ("Conflict [%d/%d]"):format(next_idx, #conflicts) }}, false, {})
      end
    end
  end
end

---Jump to the previous merge conflict marker.
function M.prev_conflict()
  local view = lib.get_current_view()

  if view and view:instanceof(StandardView.__get()) then
    ---@cast view StandardView
    local main = view.cur_layout:get_main_win()
    local curfile = main.file

    if main:is_valid() and curfile:is_valid() then
      local conflicts, cur = git.parse_conflicts(
        api.nvim_buf_get_lines(curfile.bufnr, 0, -1, false),
        main.id
      )

      if #conflicts > 0 then
        local cur_idx = utils.vec_indexof(conflicts, cur)
        local prev_idx = (cur_idx == -1) and 1 or (cur_idx - 2) % #conflicts + 1
        local prev_conflict = conflicts[prev_idx]
        local curwin = api.nvim_get_current_win()

        api.nvim_win_call(main.id, function()
          api.nvim_win_set_cursor(main.id, { prev_conflict.first, 0 })

          if curwin ~= main.id then
            -- HACK: Trigger sync for the scrollbind + cursorbind
            vim.cmd([[exe "norm! \<c-e>\<c-y>"]])
          end
        end)

        api.nvim_echo({{ ("Conflict [%d/%d]"):format(prev_idx, #conflicts) }}, false, {})
      end
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

---@param kind "ours"|"theirs"|"base"|"local"
local function diff_copy_target(kind)
  local view = lib.get_current_view() --[[@as DiffView|FileHistoryView ]]
  local file = view.cur_entry

  if file then
    local layout = file.layout
    local bufnr

    if layout:instanceof(Diff3.__get()) then
      ---@cast layout Diff3
      if kind == "ours" then
        bufnr = layout.a.file.bufnr
      elseif kind == "theirs" then
        bufnr = layout.c.file.bufnr
      elseif kind == "local" then
        bufnr = layout.b.file.bufnr
      end
    elseif layout:instanceof(Diff4.__get()) then
      ---@cast layout Diff4
      if kind == "ours" then
        bufnr = layout.a.file.bufnr
      elseif kind == "theirs" then
        bufnr = layout.c.file.bufnr
      elseif kind == "base" then
        bufnr = layout.d.file.bufnr
      elseif kind == "local" then
        bufnr = layout.b.file.bufnr
      end
    end

    if bufnr then return bufnr end
  end
end

---@param target "ours"|"theirs"|"base"|"all"|"none"
function M.conflict_choose(target)
  return function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      local main = view.cur_layout:get_main_win()
      local curfile = main.file

      if main:is_valid() and curfile:is_valid() then
        local _, cur = git.parse_conflicts(
          api.nvim_buf_get_lines(curfile.bufnr, 0, -1, false),
          main.id
        )

        if cur then
          local content

          if target == "ours" then content = cur.ours.content
          elseif target == "theirs" then content = cur.theirs.content
          elseif target == "base" then content = cur.base.content
          elseif target == "all" then
            content = utils.vec_join(
              cur.ours.content,
              cur.base.content,
              cur.theirs.content
            )
          end

          api.nvim_buf_set_lines(curfile.bufnr, cur.first - 1, cur.last, false, content or {})
        end
      end
    end
  end
end

---@param target "ours"|"theirs"|"base"|"local"
function M.diffget(target)
  return function()
    local bufnr = diff_copy_target(target)

    if bufnr and api.nvim_buf_is_valid(bufnr) then
      vim.cmd("diffget " .. bufnr)
    end
  end
end

---@param target "ours"|"theirs"|"base"|"local"
function M.diffput(target)
  return function()
    local bufnr = diff_copy_target(target)

    if bufnr and api.nvim_buf_is_valid(bufnr) then
      vim.cmd("diffput " .. bufnr)
    end
  end
end

function M.cycle_layout()
  local layout_cycles = {
    standard = {
      Diff2Hor.__get(),
      Diff2Ver.__get(),
    },
    merge_tool = {
      Diff3Hor.__get(),
      Diff3Ver.__get(),
      Diff3Mixed.__get(),
      Diff4Mixed.__get(),
      Diff1.__get(),
    }
  }

  local view = lib.get_current_view()

  if not view then return end

  local layouts, files, cur_file

  if view:instanceof(FileHistoryView.__get()) then
    ---@cast view FileHistoryView
    layouts = layout_cycles.standard
    files = view.panel:list_files()
    cur_file = view:cur_file()
  elseif view:instanceof(DiffView.__get()) then
    ---@cast view DiffView
    cur_file = view.cur_entry

    if cur_file then
      layouts = cur_file.kind == "conflicting"
          and layout_cycles.merge_tool
          or layout_cycles.standard
      files = cur_file.kind == "conflicting"
          and view.files.conflicting
          or utils.vec_join(view.panel.files.working, view.panel.files.staged)
    end
  else
    return
  end

  for _, entry in ipairs(files) do
    local cur_layout = entry.layout
    local next_layout = layouts[utils.vec_indexof(layouts, cur_layout:class()) % #layouts + 1]
    entry:convert_layout(next_layout)
  end

  if cur_file then
    local was_focused = view.cur_layout:is_focused()
    view:set_file(cur_file, false)

    if was_focused then
      view.cur_layout:get_main_win():focus()
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
