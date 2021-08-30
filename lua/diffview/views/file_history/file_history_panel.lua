local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local git = require("diffview.git.utils")
local Panel = require("diffview.ui.panel").Panel
local LogEntry = require("diffview.git.log_entry").LogEntry
local FHOptionPanel = require("diffview.views.file_history.option_panel").FHOptionPanel
local api = vim.api
local M = {}

---@class LogOptions
---@field follow boolean
---@field all boolean
---@field merges boolean
---@field no_merges boolean
---@field reverse boolean
---@field max_count integer
---@field author string
---@field grep string

---@class FileHistoryPanel
---@field git_root string
---@field entries LogEntry[]
---@field path_args string[]
---@field log_options LogOptions
---@field cur_item {[1]: LogEntry, [2]: FileEntry}
---@field single_file boolean
---@field width integer
---@field height integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field option_panel FHOptionPanel
---@field option_mapping string
---@field components any
local FileHistoryPanel = Panel
FileHistoryPanel = oop.create_class("FileHistoryPanel", Panel)

FileHistoryPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = table.concat({
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "VertSplit:DiffviewVertSplit",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  }, ","),
})

FileHistoryPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFileHistory",
})

---FileHistoryPanel constructor.
---@param git_root string
---@param entries LogEntry[]
---@param path_args string[]
---@param log_options LogOptions
---@return FileHistoryPanel
function FileHistoryPanel:init(git_root, entries, path_args, log_options)
  local conf = config.get_config()
  FileHistoryPanel:super().init(self, {
    position = conf.file_history_panel.position,
    width = conf.file_history_panel.width,
    height = conf.file_history_panel.height,
    bufname = "DiffviewFileHistoryPanel",
  })
  self.git_root = git_root
  self.entries = entries
  self.path_args = path_args
  self.cur_item = {}
  self.single_file = entries[1] and entries[1].single_file
  self.option_panel = FHOptionPanel(self)
  self.log_options = {
    follow = log_options.follow or false,
    all = log_options.all or false,
    merges = log_options.merges or false,
    no_merges = log_options.no_merges or false,
    reverse = log_options.reverse or false,
    max_count = log_options.max_count or 256,
    author = log_options.author,
    grep = log_options.grep,
  }
end

---@Override
function FileHistoryPanel:open()
  FileHistoryPanel:super().open(self)
  vim.cmd("wincmd =")
end

function FileHistoryPanel:init_buffer_opts()
  local conf = config.get_config()
  local option_rhs = config.diffview_callback("options")
  for lhs, rhs in pairs(conf.key_bindings.file_history_panel) do
    if rhs == option_rhs then
      self.option_mapping = lhs
    end
    api.nvim_buf_set_keymap(self.bufid, "n", lhs, rhs, { noremap = true, silent = true })
  end
end

function FileHistoryPanel:update_components()
  local entry_schema = {}
  for _, entry in ipairs(self.entries) do
    table.insert(entry_schema, {
      name = "entry",
      context = entry,
      { name = "commit" },
      { name = "files" },
    })
  end

  ---@type any
  self.components = self.render_data:create_component({
    { name = "header" },
    {
      name = "log",
      { name = "title" },
      { name = "entries", unpack(entry_schema) },
    },
  })
end

function FileHistoryPanel:update_entries()
  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end
  self.cur_item = {}
  self.entries = git.file_history_list(self.git_root, self.path_args, self.log_options)
  self.single_file = self.entries[1] and self.entries[1].single_file
  self:update_components()
  self:render()
  self:redraw()
end

function FileHistoryPanel:num_items()
  if self.single_file then
    return #self.entries
  else
    local count = 0
    for _, entry in ipairs(self.entries) do
      count = count + #entry.files
    end
    return count
  end
end

function FileHistoryPanel:find_entry(file)
  for _, entry in ipairs(self.entries) do
    for _, f in ipairs(entry.files) do
      if f == file then
        return entry
      end
    end
  end
end

---Get the file entry under the cursor.
---@return LogEntry|FileEntry|nil
function FileHistoryPanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  local comp = self.components.comp:get_comp_on_line(line)
  if comp and (comp.name == "commit" or comp.name == "files") then
    local entry = comp.parent.context
    if comp.name == "files" then
      return entry.files[line - comp.lstart]
    end
    return entry
  end
end

function FileHistoryPanel:set_cur_file(item)
  local file = self.cur_item[2]
  if item:instanceof(LogEntry) then
    self.cur_item = { item, item.files[1] }
  else
    local entry = self:find_entry(file)
    if entry then
      self.cur_item = { entry, file }
    end
  end
end

function FileHistoryPanel:prev_file()
  local entry, file = self.cur_item[1], self.cur_item[2]

  if not (entry and file) and self:num_items() > 0 then
    self.cur_item = { self.entries[1], self.entries[1].files[1] }
    return self.cur_item[2]
  end

  if self:num_items() > 1 then
    local entry_idx = utils.tbl_indexof(self.entries, entry)
    local file_idx = utils.tbl_indexof(entry.files, file)
    if entry_idx ~= -1 and file_idx ~= -1 then
      if file_idx == 1 and #self.entries > 1 then
        -- go to prev entry
        local next_entry_idx = (entry_idx - 2) % #self.entries + 1
        local next_entry = self.entries[next_entry_idx]
        self.cur_item = { next_entry, next_entry.files[#next_entry.files] }
        self:set_entry_fold(entry, false)
        return self.cur_item[2]
      else
        -- go to prev file in cur entry
        local next_file_idx = (file_idx - 2) % #entry.files + 1
        self.cur_item = { entry, entry.files[next_file_idx] }
        return self.cur_item[2]
      end
    end
  else
    self.cur_item = { self.entries[1], self.entries[1].files[1] }
    return self.cur_item[2]
  end
end

function FileHistoryPanel:next_file()
  local entry, file = self.cur_item[1], self.cur_item[2]

  if not (entry and file) and self:num_items() > 0 then
    self.cur_item = { self.entries[1], self.entries[1].files[1] }
    return self.cur_item[2]
  end

  if self:num_items() > 1 then
    local entry_idx = utils.tbl_indexof(self.entries, entry)
    local file_idx = utils.tbl_indexof(entry.files, file)
    if entry_idx ~= -1 and file_idx ~= -1 then
      if file_idx == #entry.files and #self.entries > 1 then
        -- go to next entry
        local next_entry_idx = entry_idx % #self.entries + 1
        self.cur_item = { self.entries[next_entry_idx], self.entries[next_entry_idx].files[1] }
        self:set_entry_fold(entry, false)
        return self.cur_item[2]
      else
        -- go to next file in cur entry
        local next_file_idx = file_idx % #entry.files + 1
        self.cur_item = { entry, entry.files[next_file_idx] }
        return self.cur_item[2]
      end
    end
  else
    self.cur_item = { self.entries[1], self.entries[1].files[1] }
    return self.cur_item[2]
  end
end

function FileHistoryPanel:highlight_item(item)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if item:instanceof(LogEntry) then
    for _, comp in ipairs(self.components.log.entries) do
      if comp.context == item then
        pcall(api.nvim_win_set_cursor, self.winid, { comp.lstart, 0 })
      end
    end
  else
    for _, comp_struct in ipairs(self.components.log.entries) do
      local i = utils.tbl_indexof(comp_struct.comp.context.files, item)
      if i ~= -1 then
        if self.single_file then
          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + 1, 0 })
        else
          if comp_struct.comp.context.folded then
            self:set_entry_fold(comp_struct.comp.context, true)
            self:render()
            self:redraw()
          end
          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + i + 1, 0 })
        end
      end
    end
  end
end

function FileHistoryPanel:highlight_prev_item()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min = self.components.log.entries.comp.lstart + 1
  local max = self.components.log.entries.comp.lend

  line = utils.clamp(line - 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

function FileHistoryPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min = self.components.log.entries.comp.lstart + 1
  local max = self.components.log.entries.comp.lend

  line = utils.clamp(line + 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

function FileHistoryPanel:set_entry_fold(entry, open)
  if not self.single_file and open == entry.folded then
    entry.folded = not open
    self:render()
    self:redraw()
  end
end

function FileHistoryPanel:toggle_entry_fold(entry)
  if not self.single_file then
    entry.folded = not entry.folded
    self:render()
    self:redraw()
  end
end

function FileHistoryPanel:render()
  require("diffview.views.file_history.render").file_history_panel(self)
end

M.FileHistoryPanel = FileHistoryPanel
return M
