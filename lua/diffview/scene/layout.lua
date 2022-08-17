local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local M = {}

---@class Layout : diffview.Object
---@field windows Window[]
---@field pivot_producer fun(): integer?
local Layout = oop.create_class("Layout")

function Layout:init()
  self.windows = {}
end

---@diagnostic disable: unused-local, missing-return

---@abstract
---@param pivot? integer The window ID of the window around which the layout will be created.
function Layout:create(pivot) oop.abstract_stub() end

---@abstract
---@param rev Rev
---@param status string Git status symbol.
---@param sym string
---@return boolean
function Layout.should_null(rev, status, sym) oop.abstract_stub() end

---@abstract
---@param entry FileEntry
function Layout:use_entry(entry) oop.abstract_stub() end

---@abstract
---@return Window
function Layout:get_main_win() oop.abstract_stub() end

---@diagnostic enable: unused-local

function Layout:destroy()
  for _, win in ipairs(self.windows) do
    win:destroy()
  end
end

---Find or create a window that can be used as a pivot during layout
---creation.
---@return integer winid
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

  if vim.is_callable(self.pivot_producer) then
    local ret = self.pivot_producer()

    if ret then
      return ret
    end
  end

  vim.cmd("1windo belowright vsp")

  return api.nvim_get_current_win()
end

---@return git.File[]
function Layout:files()
  return utils.tbl_fmap(self.windows, function(v)
    return v.file
  end)
end

---Check if the buffers for all the files in the layout are loaded.
---@return boolean
function Layout:is_files_loaded()
  for _, f in ipairs(self:files()) do
    if not f:is_valid() then
      return false
    end
  end

  return true
end

---@param callback? fun()
function Layout:open_files(callback)
  local load_count = 0
  local all_loaded = self:is_files_loaded()

  for _, win in ipairs(self.windows) do
    if not all_loaded then
      win:open_null()
    end

    if win.file then
      if all_loaded then
        win:open_file()
      else
        win:load_file(function()
          load_count = load_count + 1

          if load_count == #self.windows then
            ---@diagnostic disable-next-line: redefined-local
            for _, win in ipairs(self.windows) do
              win:open_file()
            end

            self:update_windows()

            if vim.is_callable(callback) then
              ---@cast callback -?
              callback()
            end
          end
        end)
      end
    end
  end

  if all_loaded then
    self:update_windows()

    if vim.is_callable(callback) then
      ---@cast callback -?
      callback()
    end
  end
end

function Layout:open_null()
  for _, win in ipairs(self.windows) do
    win:open_null()
  end
end

---Recover a broken layout.
---@param pivot? integer
function Layout:recover(pivot)
  pivot = pivot or self:find_pivot()
  ---@cast pivot -?

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      pcall(api.nvim_win_close, win.id, true)
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
  local main = self:get_main_win()

  for _, win in ipairs(self.windows) do
    win:apply_file_winopts()
    api.nvim_win_call(win.id, function()
      if win == main then
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
