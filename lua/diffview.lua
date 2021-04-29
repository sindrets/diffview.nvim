local lib = require'diffview.lib'
local M = {}

function M.init()
end

function M.open(args)
  -- print(vim.inspect(args))
  local v = lib.parse_revs(args)
  -- print(vim.inspect(v))
  v:open()
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
