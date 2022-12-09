local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@class Layout : diffview.Object
---@field parent FileEntry
---@field windows Window[]
---@field emitter EventEmitter
---@field pivot_producer fun(): integer?
local Layout = oop.create_class("Layout")

function Layout:init(opt)
  opt = opt or {}
  self.parent = opt.parent
  self.windows = opt.windows or {}
  self.emitter = opt.emitter or EventEmitter()

  if not opt.emitter then
    local last_equalalways

    ---@param other Layout
    ---@diagnostic disable-next-line: unused-local
    self.emitter:on("create_pre", function(_, other)
      last_equalalways = vim.o.equalalways
      vim.opt.equalalways = true
    end)

    ---@param other Layout
    self.emitter:on("create_post", function(_, other)
      other:open_null()
      other:open_files()
      vim.opt.equalalways = last_equalalways
    end)
  end
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

---@diagnostic enable: unused-local, missing-return

function Layout:destroy()
  for _, win in ipairs(self.windows) do
    win:destroy()
  end
end

function Layout:clone()
  local clone = self:class()({ emitter = self.emitter }) --[[@as Layout ]]

  for i, win in ipairs(self.windows) do
    clone.windows[i]:set_id(win.id)
    clone.windows[i]:set_file(win.file)
  end

  return clone
end

---Check if any of the windows in the lauout are focused.
---@return boolean
function Layout:is_focused()
  for _, win in ipairs(self.windows) do
    if win:is_focused() then return true end
  end

  return false
end

---@param ... Window
function Layout:use_windows(...)
  local wins = { ... }

  for i = 1, select("#", ...) do
    local win = wins[i]
    win.parent = self

    if utils.vec_indexof(self.windows, win) == -1 then
      table.insert(self.windows, win)
    end
  end
end

---Find or create a window that can be used as a pivot during layout
---creation.
---@return integer winid
function Layout:find_pivot()
  local last_win = api.nvim_get_current_win()

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

  local pivot = api.nvim_get_current_win()

  if api.nvim_win_is_valid(last_win) then
    api.nvim_set_current_win(last_win)
  end

  return pivot
end

---@return vcs.File[]
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
  if #self:files() < #self.windows then
    self:open_null()

    if vim.is_callable(callback) then
      ---@cast callback -?
      callback()
    end

    self.emitter:emit("files_opened")

    return
  end

  local load_count = 0
  local all_loaded = self:is_files_loaded()

  vim.cmd("diffoff!")

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

            self:sync_scroll()

            if vim.is_callable(callback) then
              ---@cast callback -?
              callback()
            end

            self.emitter:emit("files_opened")
          end
        end)
      end
    end
  end

  if all_loaded then
    self:sync_scroll()

    if vim.is_callable(callback) then
      ---@cast callback -?
      callback()
    end

    self.emitter:emit("files_opened")
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

---Sync the scrollbind.
function Layout:sync_scroll()
  local curwin = api.nvim_get_current_win()
  local target, max = nil, 0

  for _, win in ipairs(self.windows) do
    local lcount = api.nvim_buf_line_count(win.file.bufnr)
    if lcount > max then target, max = win, lcount end
  end

  for _, win in ipairs(self.windows) do
    api.nvim_win_call(win.id, function()
      if win == target then
        -- Scroll to trigger the scrollbind and sync the windows. This works more
        -- consistently than calling `:syncbind`.
        vim.cmd([[exe "norm! \<c-e>\<c-y>"]])
      end

      if win.id ~= curwin then
        api.nvim_exec_autocmds("WinLeave", { modeline = false })
      end
    end)
  end
end

function Layout:gs_update_folds() end

M.Layout = Layout
return M
