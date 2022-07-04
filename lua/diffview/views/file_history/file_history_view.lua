local CommitLogPanel = require("diffview.ui.panels.commit_log_panel").CommitLogPanel
local Event = require("diffview.events").Event
local EventEmitter = require("diffview.events").EventEmitter
local FileEntry = require("diffview.views.file_entry").FileEntry
local FileHistoryPanel = require("diffview.views.file_history.file_history_panel").FileHistoryPanel
local LayoutMode = require("diffview.views.view").LayoutMode
local StandardView = require("diffview.views.standard.standard_view").StandardView
local git = require("diffview.git.utils")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local JobStatus = git.JobStatus
local api = vim.api

local M = {}

---@class FileHistoryView : StandardView
---@field git_root string
---@field git_dir string
---@field panel FileHistoryPanel
---@field commit_log_panel CommitLogPanel
---@field path_args string[]
---@field raw_args string[]
---@field valid boolean
local FileHistoryView = oop.create_class("FileHistoryView", StandardView)

function FileHistoryView:init(opt)
  self.valid = false
  self.git_dir = git.git_dir(opt.git_root)

  if not self.git_dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(opt.git_root))
    )
    return
  end

  self.emitter = EventEmitter()
  self.layout_mode = FileHistoryView.get_layout_mode()
  self.ready = false
  self.closing = false
  self.nulled = false
  self.winopts = { left = {}, right = {} }
  self.git_root = opt.git_root
  self.path_args = opt.path_args
  self.raw_args = opt.raw_args
  self.panel = FileHistoryPanel(
    self,
    self.git_root,
    {},
    self.path_args,
    self.raw_args,
    opt.log_options,
    { base = opt.base, }
  )
  self.valid = true
end

function FileHistoryView:post_open()
  self.commit_log_panel = CommitLogPanel(self.git_root, {
    name = ("diffview://%s/log/%d/%s"):format(self.git_dir, self.tabpage, "commit_log"),
  })

  self:init_event_listeners()

  vim.schedule(function()
    self:file_safeguard()
    ---@diagnostic disable-next-line: unused-local
    self.panel:update_entries(function(entries, status)
      if status < JobStatus.ERROR and not self.panel:cur_file() then
        local file = self.panel:next_file()
        if file then
          self:set_file(file)
        end
      end
    end)
    self.ready = true
  end)
end

---@Override
function FileHistoryView:close()
  if not self.closing then
    self.closing = true
    for _, entry in ipairs(self.panel.entries or {}) do
      entry:destroy()
    end
    self.commit_log_panel:destroy()
    FileHistoryView:super().close(self)
  end
end

function FileHistoryView:next_item()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.panel:num_items() > 1 or self.nulled then
    vim.cmd("diffoff!")
    local cur = self.panel:next_file()
    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      cur:load_buffers(self.git_root, self.left_winid, self.right_winid, function()
        self:update_windows()
      end)

      return cur
    end
  end
end

function FileHistoryView:prev_item()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.panel:num_items() > 1 or self.nulled then
    vim.cmd("diffoff!")
    local cur = self.panel:prev_file()
    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      cur:load_buffers(self.git_root, self.left_winid, self.right_winid, function()
        self:update_windows()
      end)

      return cur
    end
  end
end

function FileHistoryView:set_file(file, focus)
  self:ensure_layout()
  if self:file_safeguard() or not file then
    return
  end

  local entry = self.panel:find_entry(file)
  if entry then
    vim.cmd("diffoff!")
    self.panel:set_cur_item({ entry, file })
    self.panel:highlight_item(file)
    self.nulled = false
    file:load_buffers(self.git_root, self.left_winid, self.right_winid, function()
      self:update_windows()
    end)

    if focus then
      api.nvim_set_current_win(self.right_winid)
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
    self:post_layout()
    self:set_file(self.panel.cur_item[2])
  elseif not state.right_win then
    api.nvim_set_current_win(self.left_winid)
    vim.cmd("belowright " .. split_cmd)
    self.right_winid = api.nvim_get_current_win()
    self.panel:open()
    self:post_layout()
    self:set_file(self.panel.cur_item[2])
  end

  self.ready = true
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function FileHistoryView:file_safeguard()
  if self.panel:num_items() == 0 then
    local cur = self.panel.cur_item[2]
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
---@return FileEntry?
function FileHistoryView:infer_cur_file()
  if self.panel:is_focused() then
    local item = self.panel:get_item_at_cursor()
    if item and not item:instanceof(FileEntry) then
      return item.files[1]
    end
    return item
  else
    return self.panel.cur_item[2]
  end
end

---Check whether or not the instantiation was successful.
---@return boolean
function FileHistoryView:is_valid()
  return self.valid
end

M.FileHistoryView = FileHistoryView
return M
