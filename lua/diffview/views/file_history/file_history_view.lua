local oop = require("diffview.oop")
local utils = require("diffview.utils")
local git = require("diffview.git")
local Event = require("diffview.events").Event
local EventEmitter = require("diffview.events").EventEmitter
local StandardView = require("diffview.views.standard.standard_view").StandardView
local LayoutMode = require("diffview.views.view").LayoutMode
local FileEntry = require("diffview.views.file_entry").FileEntry
local FileHistoryPanel = require("diffview.views.file_history.file_history_panel").FileHistoryPanel
local api = vim.api

local M = {}

---@class FileHistoryView
---@field git_root string
---@field git_dir string
---@field panel FileHistoryPanel
---@field target_path string
---@field files FileDict
---@field file_idx integer
local FileHistoryView = StandardView
FileHistoryView = oop.create_class("FileHistoryView", StandardView)

function FileHistoryView:init(opt)
  self.emitter = EventEmitter()
  self.layout_mode = FileHistoryView.get_layout_mode()
  self.ready = false
  self.nulled = false
  self.git_root = opt.git_root
  self.git_dir = git.git_dir(self.git_root)
  self.target_path = opt.target_path
  self.files = git.file_history_list(self.git_root, self.target_path, opt.max_count)
  self.file_idx = 1
  self.panel = FileHistoryPanel(self.git_root, self.files)
end

---@Override
function FileHistoryView:open()
  vim.cmd("tab split")
  self.tabpage = api.nvim_get_current_tabpage()
  self:init_layout()
  self:init_event_listeners()
  vim.schedule(function()
    local file = self:cur_file()
    if file then
      self:set_file(file)
    else
      self:file_safeguard()
    end
    self.ready = true
  end)
end

---@Override
function FileHistoryView:close()
  for _, file in self.files:ipairs() do
    file:destroy()
  end
  FileHistoryView:super().close(self)
end

---Get the current file.
---@return FileEntry
function FileHistoryView:cur_file()
  if self.files:size() > 0 then
    return self.files[utils.clamp(self.file_idx, 1, self.files:size())]
  end
  return nil
end

function FileHistoryView:next_file()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    self.file_idx = self.file_idx % self.files:size() + 1
    vim.cmd("diffoff!")
    cur = self.files[self.file_idx]
    cur:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.panel:highlight_file(self:cur_file())
    self.nulled = false

    return cur
  end
end

function FileHistoryView:prev_file()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    self.file_idx = (self.file_idx - 2) % self.files:size() + 1
    vim.cmd("diffoff!")
    cur = self.files[self.file_idx]
    cur:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.panel:highlight_file(self:cur_file())
    self.nulled = false

    return cur
  end
end

function FileHistoryView:set_file(file, focus)
  self:ensure_layout()
  if self:file_safeguard() or not file then
    return
  end

  for i, f in self.files:ipairs() do
    if f == file then
      local cur = self:cur_file()
      if cur then
        cur:detach_buffers()
      end
      self.file_idx = i
      vim.cmd("diffoff!")
      self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
      self.panel:highlight_file(self:cur_file())
      self.nulled = false

      if focus then
        api.nvim_set_current_win(self.right_winid)
      end
    end
  end
end

---@Override
---Recover the layout after the user has messed it up.
---@param state LayoutState
function FileHistoryView:recover_layout(state)
  self.ready = false

  if not state.tabpage then
    vim.cmd("tab split")
    self.tabpage = api.nvim_get_current_tabpage()
    self.panel:close()
    self:init_layout()
    self.ready = true
    return
  end

  api.nvim_set_current_tabpage(self.tabpage)
  self.panel:close()
  local split_cmd = self.layout_mode == LayoutMode.VERTICAL and "sp" or "vsp"

  if not state.left_win and not state.right_win then
    self:init_layout()
  elseif not state.left_win then
    api.nvim_set_current_win(self.right_winid)
    vim.cmd("aboveleft " .. split_cmd)
    self.left_winid = api.nvim_get_current_win()
    self.panel:open()
    self:set_file(self:cur_file())
  elseif not state.right_win then
    api.nvim_set_current_win(self.left_winid)
    vim.cmd("belowright " .. split_cmd)
    self.right_winid = api.nvim_get_current_win()
    self.panel:open()
    self:set_file(self:cur_file())
  end

  self.ready = true
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function FileHistoryView:file_safeguard()
  if self.files:size() == 0 then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    FileEntry.load_null_buffer(self.left_winid)
    FileEntry.load_null_buffer(self.right_winid)
    self.nulled = true
    return true
  end
  return false
end

function FileHistoryView:on_files_staged(callback)
  self.emitter:on(Event.FILES_STAGED, callback)
end

function FileHistoryView:init_event_listeners()
  local listeners = require("diffview.views.file_history.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

---Infer the current selected file. If the file panel is focused: return the
---file entry under the cursor. Otherwise return the file open in the view.
---Returns nil if no file is open in the view, or there is no entry under the
---cursor in the file panel.
---@return FileEntry|nil
function FileHistoryView:infer_cur_file()
  if self.panel:is_focused() then
    return self.panel:get_file_at_cursor()
  else
    return self:cur_file()
  end
end

M.FileHistoryView = FileHistoryView
return M
