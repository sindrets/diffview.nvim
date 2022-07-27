local oop = require("diffview.oop")

local api = vim.api
local M = {}

---@class Layout : diffview.Object
---@field windows Window[]
local Layout = oop.create_class("Layout")

function Layout:init()
  self.windows = {}
end

---@diagnostic disable unused-local

---@abstract
---@param pivot? integer The window ID of the window around which the layout will be created.
function Layout:create(pivot) oop.abstract_stub() end

---@abstract
---@param rev Rev
---@param status string Git status symbol.
---@param sym string
function Layout.should_null(rev, status, sym) oop.abstract_stub() end

---@diagnostic enable unused-local

---Find or create a window that can be used as a pivot during layout
---creation.
---@return integer? winid
function Layout:find_pivot()
  for _, win in ipairs(self.windows) do
    if win:is_valid() then
      local ret

      api.nvim_win_call(win.id, function()
        vim.cmd("aboveleft vsp")
        ret = api.nvim_get_current_win()
      end)

      return ret
    end
  end

  vim.cmd("1windo belowright vsp")

  return api.nvim_get_current_win()
end

---Recover a broken layout.
---@param pivot? integer
function Layout:recover(pivot)
  ---@cast pivot -?
  pivot = pivot or self:find_pivot()

  for _, winid in ipairs(self.windows) do
    if winid ~= pivot then
      api.nvim_win_close(winid, true)
    end
  end

  self.windows = {}
  self:create(pivot)
end

---@alias Layout.State { [Window]: boolean, valid: boolean }

---Check the validity of all composing layout windows.
---@return Layout.State
function Layout:validate()
  local state = { valid = true }

  for _, win in ipairs(self.windows) do
    state[win] = win:is_valid()
    if not state[win] then
      state.valid = false
    end
  end

  return state
end

---Check the validity if the layout.
---@return boolean
function Layout:is_valid()
  return self:validate().valid
end

---Validate the layout and recover if necessary.
function Layout:ensure()
  local state = self:validate()

  if not state.valid then
    self:recover()
  end
end

---Save window local options.
function Layout:save_winopts()
  for _, win in ipairs(self.windows) do
    win:_save_winopts()
  end
end

---Restore saved window local options.
function Layout:restore_winopts()
  for _, win in ipairs(self.windows) do
    win:_restore_winopts()
  end
end

function Layout:detach_files()
  for _, win in ipairs(self.windows) do
    win:detach_file()
  end
end

---Reapply window local options, and sync the scrollbind.
function Layout:update_windows()
  local curwin = api.nvim_get_current_win()

  for i, win in ipairs(self.windows) do
    win:apply_file_winopts()
    api.nvim_win_call(win.id, function()
      if i == #self.windows then
        -- Scroll to trigger the scrollbind and sync the windows. This works more
        -- consistently than calling `:syncbind`.
        vim.cmd([[exe "norm! \<c-e>\<c-y>"]])
      end

      if win.id ~= curwin then
        vim.cmd("do <nomodeline> WinLeave")
      end
    end)
  end
end

M.Layout = Layout
return M
