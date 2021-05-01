local lib = require'diffview.lib'
local config = require'diffview.config'
local colors = require'diffview.colors'
local M = {}

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  colors.setup()
end

function M.open(args)
  local view = lib.parse_revs(args)
  if view then
    view:open()
  end
end

function M.close(tabpage)
  if tabpage then
    vim.schedule(function ()
      lib.dispose_stray_views()
    end)
    return
  end

  local view = lib.get_current_diffview()
  if view then
    view:close()
    lib.dispose_view(view)
  end
end

function M.on_tab_enter()
  local view = lib.get_current_diffview()
  if view then
    view:on_enter()
  end
end

function M.on_tab_leave()
  local view = lib.get_current_diffview()
  if view then
    view:on_leave()
  end
end

function M.on_buf_write_post()
  for _, view in ipairs(lib.views) do
    view:on_buf_write_post()
  end
end

function M.on_buf_win_enter()
  local view = lib.get_current_diffview()
  if view then
    view:on_buf_win_enter()
  end
end

function M.update_colors()
  colors.setup()
  lib.update_colors()
end

function M.on_keypress(event_name)
  if M.keypress_event_cbs[event_name] then
    M.keypress_event_cbs[event_name]()
  end
end

M.keypress_event_cbs = {
  select_next_entry = function ()
    local view = lib.get_current_diffview()
    if view then view:next_file() end
  end,
  select_prev_entry = function ()
    local view = lib.get_current_diffview()
    if view then view:prev_file() end
  end,
  next_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      view.file_panel:highlight_next_file()
    end
  end,
  prev_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      view.file_panel:highlight_prev_file()
    end
  end,
  select_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      local file = view.file_panel:get_file_at_cursor()
      if file then view:set_file(file, true) end
    end
  end,
  focus_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view.file_panel:focus(true)
    end
  end,
  toggle_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view.file_panel:toggle()
    end
  end,
  refresh_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view:update_files()
    end
  end
}

M.init()

return M
