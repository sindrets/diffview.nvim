local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local CommitLogPanel = lazy.access("diffview.ui.panels.commit_log_panel", "CommitLogPanel") ---@type CommitLogPanel|LazyModule
local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local FileHistoryPanel = lazy.access("diffview.scene.views.file_history.file_history_panel", "FileHistoryPanel") ---@type FileHistoryPanel|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local LogEntry = lazy.access("diffview.vcs.log_entry", "LogEntry") ---@type LogEntry|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"

local api = vim.api
local await = async.await

local M = {}

---@class FileHistoryView : StandardView
---@operator call:FileHistoryView
---@field adapter VCSAdapter
---@field panel FileHistoryPanel
---@field commit_log_panel CommitLogPanel
---@field valid boolean
local FileHistoryView = oop.create_class("FileHistoryView", StandardView.__get())

function FileHistoryView:init(opt)
  self.valid = false
  self.adapter = opt.adapter

  self:super({
    panel = FileHistoryPanel({
      parent = self,
      adapter = self.adapter,
      entries = {},
      log_options = opt.log_options,
    }),
  })

  self.valid = true
end

function FileHistoryView:post_open()
  self.commit_log_panel = CommitLogPanel(self.adapter, {
    name = ("diffview://%s/log/%d/%s"):format(self.adapter.ctx.dir, self.tabpage, "commit_log"),
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

---@override
function FileHistoryView:close()
  if not self.closing:check() then
    self.closing:send()

    for _, entry in ipairs(self.panel.entries or {}) do
      entry:destroy()
    end

    self.commit_log_panel:destroy()
    FileHistoryView.super_class.close(self)
  end
end

---@return FileEntry?
function FileHistoryView:cur_file()
  return self.panel.cur_item[2]
end

---@private
---@param self FileHistoryView
---@param file FileEntry
FileHistoryView._set_file = async.void(function(self, file)
  self.panel:render()
  self.panel:redraw()
  vim.cmd("redraw")

  self.cur_layout:detach_files()
  local cur_entry = self.cur_entry
  self.emitter:emit("file_open_pre", file, cur_entry)
  self.nulled = false

  await(self:use_entry(file))

  local log_options = self.panel:get_log_options()

  -- For line tracing diffs: create custom folds derived from the diff patch
  -- hunks. Should not be used with custom `++base` as then we won't know
  -- where to create the custom folds in the base file.
  if log_options.L and next(log_options.L) and not log_options.base then
    local log_entry = self.panel.cur_item[1]
    local diff = log_entry:get_diff(file.path)

    if diff and not file:has_patch_folds() then
      file:update_patch_folds(diff)

      for _, win in ipairs(self.cur_layout.windows) do
        win:use_winopts({ foldmethod = "manual" })
        win:apply_custom_folds()
      end
    end
  end

  self.emitter:emit("file_open_post", file, cur_entry)

  if not self.cur_entry.opened then
    self.cur_entry.opened = true
    DiffviewGlobal.emitter:emit("file_open_new", file)
  end
end)

function FileHistoryView:next_item()
  self:ensure_layout()

  if self:file_safeguard() then return end

  if self.panel:num_items() > 1 or self.nulled then
    local cur = self.panel:next_file()

    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      self:_set_file(cur)

      return cur
    end
  end
end

function FileHistoryView:prev_item()
  self:ensure_layout()

  if self:file_safeguard() then return end

  if self.panel:num_items() > 1 or self.nulled then
    local cur = self.panel:prev_file()

    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      self:_set_file(cur)

      return cur
    end
  end
end

---@param self FileHistoryView
---@param file FileEntry
---@param focus? boolean
FileHistoryView.set_file = async.void(function(self, file, focus)
  ---@diagnostic disable: invisible
  self:ensure_layout()

  if self:file_safeguard() or not file then return end

  local entry = self.panel:find_entry(file)
  local cur_entry = self.panel.cur_item[1]

  if entry then
    if cur_entry and entry ~= cur_entry then
      self.panel:set_entry_fold(cur_entry, false)
    end

    self.panel:set_cur_item({ entry, file })
    self.panel:highlight_item(file)
    self.nulled = false
    await(self:_set_file(file))

    if focus then
      api.nvim_set_current_win(self.cur_layout:get_main_win().id)
    end
  end
  ---@diagnostic enable: invisible
end)


---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function FileHistoryView:file_safeguard()
  if self.panel:num_items() == 0 then
    local cur = self.panel.cur_item[2]

    if cur then
      cur.layout:detach_files()
    end

    self.cur_layout:open_null()
    self.nulled = true

    return true
  end

  return false
end

function FileHistoryView:on_files_staged(callback)
  self.emitter:on(EventName.FILES_STAGED, callback)
end

function FileHistoryView:init_event_listeners()
  local listeners = require("diffview.scene.views.file_history.listeners")(self)
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

    if LogEntry.__get():ancestorof(item) then
      ---@cast item LogEntry
      return item.files[1]
    end

    return item --[[@as FileEntry ]]
  end

  return self.panel.cur_item[2]
end

---Check whether or not the instantiation was successful.
---@return boolean
function FileHistoryView:is_valid()
  return self.valid
end

---@override
function FileHistoryView.get_default_layout_name()
  return config.get_config().view.file_history.layout
end

---@override
---@return Layout # (class) The default layout class.
function FileHistoryView.get_default_layout()
  local name = FileHistoryView.get_default_layout_name()

  if name == -1 then
    return FileHistoryView.get_default_diff2()
  end

  return config.name_to_layout(name --[[@as string ]])
end

M.FileHistoryView = FileHistoryView
return M
