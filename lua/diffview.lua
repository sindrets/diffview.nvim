local lib = require'diffview.lib'
local colors = require'diffview.colors'
local M = {}

function M.init()
  colors.setup()
end

function M.open(args)
  -- print(vim.inspect(args))
  local view = lib.parse_revs(args)
  -- print(vim.inspect(v))
  view:open()
end

function M.close(tabpage)
  local view
  if tabpage then
    view = lib.tabpage_to_view(tabpage)
  else
    view = lib.get_current_diffview()
  end

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
  next_file = function ()
    local view = lib.get_current_diffview()
    if view then view:next_file() end
  end,
  prev_file = function ()
    local view = lib.get_current_diffview()
    if view then view:prev_file() end
  end,
}

M.init()

return M
