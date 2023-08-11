local async = require("diffview.async")
local lazy = require("diffview.lazy")

local FHOptionPanel = lazy.access("diffview.scene.views.file_history.option_panel", "FHOptionPanel") ---@type FHOptionPanel|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local LogEntry = lazy.access("diffview.vcs.log_entry", "LogEntry") ---@type LogEntry|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel") ---@type Panel|LazyModule
local PerfTimer = lazy.access("diffview.perf", "PerfTimer") ---@type PerfTimer|LazyModule
local Signal = lazy.access("diffview.control", "Signal") ---@type Signal|LazyModule
local WorkPool = lazy.access("diffview.control", "WorkPool") ---@type WorkPool|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local panel_renderer = lazy.require("diffview.scene.views.file_history.render") ---@module "diffview.scene.views.file_history.render"
local renderer = lazy.require("diffview.renderer") ---@module "diffview.renderer"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@type PerfTimer
local perf_render = PerfTimer("[FileHistoryPanel] render")
---@type PerfTimer
local perf_update = PerfTimer("[FileHistoryPanel] update")

---@alias FileHistoryPanel.CurItem { [1]: LogEntry, [2]: FileEntry }

---@class FileHistoryPanel : Panel
---@field parent FileHistoryView
---@field adapter VCSAdapter
---@field entries LogEntry[]
---@field rev_range RevRange
---@field log_options ConfigLogOptions
---@field cur_item FileHistoryPanel.CurItem
---@field single_file boolean
---@field work_pool WorkPool
---@field shutdown Signal
---@field updating boolean
---@field render_data RenderData
---@field option_panel FHOptionPanel
---@field option_mapping string
---@field help_mapping string
---@field components CompStruct
---@field constrain_cursor function
local FileHistoryPanel = oop.create_class("FileHistoryPanel", Panel.__get())

FileHistoryPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  },
})

FileHistoryPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFileHistory",
})

---@class FileHistoryPanel.init.Opt
---@field parent FileHistoryView
---@field adapter VCSAdapter
---@field entries LogEntry[]
---@field log_options LogOptions

---FileHistoryPanel constructor.
---@param opt FileHistoryPanel.init.Opt
function FileHistoryPanel:init(opt)
  local conf = config.get_config()

  self:super({
    config = conf.file_history_panel.win_config,
    bufname = "DiffviewFileHistoryPanel",
  })

  self.parent = opt.parent
  self.adapter = opt.adapter
  self.entries = opt.entries
  self.cur_item = {}
  self.single_file = opt.entries[1] and opt.entries[1].single_file
  self.work_pool = WorkPool()
  self.shutdown = Signal()
  self.updating = false
  self.option_panel = FHOptionPanel(self, self.adapter.flags)
  self.log_options = {
    single_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options[self.adapter.config_key].single_file,
      opt.log_options
    ),
    multi_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options[self.adapter.config_key].multi_file,
      opt.log_options
    ),
  }

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FileHistoryPanel:open()
  FileHistoryPanel.super_class.open(self)
  vim.cmd("wincmd =")
end

---@override
---@param self FileHistoryPanel
FileHistoryPanel.destroy = async.sync_void(function(self)
  self.shutdown:send()

  await(self.work_pool)
  await(async.scheduler())

  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end

  self.entries = nil
  self.cur_item = nil
  self.option_panel:destroy()
  self.option_panel = nil
  self.render_data:destroy()

  if self.components then
    renderer.destroy_comp_struct(self.components)
  end

  FileHistoryPanel.super_class.destroy(self)
end)

function FileHistoryPanel:setup_buffer()
  local conf = config.get_config()
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }

  for _, mapping in ipairs(conf.keymaps.file_history_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end

  local option_keymap = config.find_option_keymap(conf.keymaps.file_history_panel)
  if option_keymap then self.option_mapping = option_keymap[2] end

  local help_keymap = config.find_help_keymap(conf.keymaps.file_history_panel)
  if help_keymap then self.help_mapping = help_keymap[2] end
end

function FileHistoryPanel:update_components()
  self.render_data:destroy()
  if self.components then
    renderer.destroy_comp_struct(self.components)
  end

  local entry_schema = { name = "entries" }
  for i, entry in ipairs(utils.vec_slice(self.entries)) do
    if self.updating and i > 128 then
      break
    end
    table.insert(entry_schema, {
      name = "entry",
      context = entry,
      { name = "commit" },
      { name = "files" },
    })
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    { name = "header" },
    {
      name = "log",
      { name = "title" },
      entry_schema,
    },
  })

  self.constrain_cursor = renderer.create_cursor_constraint({ self.components.log.entries.comp })
end

---@param self FileHistoryPanel
---@param callback function
FileHistoryPanel.update_entries = async.wrap(function(self, callback)
  perf_update:reset()
  local checkout = self.work_pool:check_in()

  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end

  panel_renderer.clear_cache(self)
  self.cur_item = {}
  self.entries = {}
  self.updating = true

  local stream = self.adapter:file_history({
    log_opt = self.log_options,
    layout_opt = { default_layout = self.parent.get_default_layout() },
  })

  self:sync()

  local render = debounce.throttle_render(
    15,
    function()
      if self.shutdown:check() then return end
      if not self:cur_file() then
        self:update_components()
        self.parent:next_item()
      else
        self:sync()
      end

      vim.cmd("redraw")
    end
  )

  local ret = {}

  for _, item in stream:iter() do
    if self.shutdown:check() then
      stream:close(self.shutdown:new_consumer())
      ret = { nil, JobStatus.KILLED }
      break
    end

    ---@type JobStatus, LogEntry?, string?
    local status, entry, msg = unpack(item, 1, 3)

    if status == JobStatus.ERROR then
      utils.err(fmt("Updating file history failed! Error message: %s", msg), true)
      ret = { nil, JobStatus.ERROR, msg }
      break
    elseif status == JobStatus.SUCCESS then
      ret = { self.entries, status }
      perf_update:time()
      logger:fmt_info(
        "[FileHistory] Completed update for %d entries successfully (%.3f ms).",
        #self.entries,
        perf_update.final_time
      )
    elseif status == JobStatus.PROGRESS then
      ---@cast entry -?
      local was_empty = #self.entries == 0
      self.entries[#self.entries+1] = entry

      if was_empty then
        self.single_file = self.entries[1].single_file
      end

      render()
    else
      error("Unexpected state!")
    end
  end

  await(async.scheduler())
  self.updating = false

  if not self.shutdown:check() then
    self:sync()
    self.option_panel:sync()
    vim.cmd("redraw")
  end

  checkout:send()
  callback(unpack(ret, 1, 3))
end)

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

---@return FileEntry[]
function FileHistoryPanel:list_files()
  local files = {}

  for _, entry in ipairs(self.entries) do
    for _, file in ipairs(entry.files) do
      table.insert(files, file)
    end
  end

  return files
end

---@param file FileEntry
function FileHistoryPanel:find_entry(file)
  for _, entry in ipairs(self.entries) do
    for _, f in ipairs(entry.files) do
      if f == file then
        return entry
      end
    end
  end
end

---Get the log or file entry under the cursor.
---@return (LogEntry|FileEntry)?
function FileHistoryPanel:get_item_at_cursor()
  if not self:is_open() and self:buf_loaded() then return end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local comp = self.components.comp:get_comp_on_line(line)

  if comp and (comp.name == "commit" or comp.name == "files") then
    local entry = comp.parent.context --[[@as table ]]

    if comp.name == "files" then
      return entry.files[line - comp.lstart]
    end

    return entry
  end
end

---Get the parent log entry of the item under the cursor.
---@return LogEntry?
function FileHistoryPanel:get_log_entry_at_cursor()
  local item = self:get_item_at_cursor()
  if not item then return end

  if item:instanceof(LogEntry.__get()) then
    return item --[[@as LogEntry ]]
  end

  return self:find_entry(item --[[@as FileEntry ]])
end

---@param new_item FileHistoryPanel.CurItem
function FileHistoryPanel:set_cur_item(new_item)
  if self.cur_item[2] then
    self.cur_item[2]:set_active(false)
  end

  self.cur_item = new_item

  if self.cur_item and self.cur_item[2] then
    self.cur_item[2]:set_active(true)
  end
end

function FileHistoryPanel:set_entry_from_file(item)
  local file = self.cur_item[2]

  if item:instanceof(LogEntry.__get()) then
    self:set_cur_item({ item, item.files[1] })
  else
    local entry = self:find_entry(file)

    if entry then
      self:set_cur_item({ entry, file })
    end
  end
end

function FileHistoryPanel:cur_file()
  return self.cur_item[2]
end

---@private
---@param entry_idx integer
---@param file_idx integer
---@param offset integer
---@return LogEntry?
---@return FileEntry?
function FileHistoryPanel:_get_entry_by_file_offset(entry_idx, file_idx, offset)
  local cur_entry = self.entries[entry_idx]

  if cur_entry.files[file_idx + offset] then
    return cur_entry, cur_entry.files[file_idx + offset]
  end

  local sign = utils.sign(offset)
  local delta = math.abs(offset) - (sign > 0 and #cur_entry.files - file_idx or file_idx - 1)
  local i = (entry_idx + (sign > 0 and 0 or -2)) % #self.entries + 1

  while i ~= entry_idx do
    local files = self.entries[i].files

    if (#files - delta) >= 0 then
      local target_file = sign > 0 and files[delta] or files[#files - (delta - 1)]
      return self.entries[i], target_file
    end

    delta = delta - #files
    i = (i + (sign > 0 and 0 or -2)) % #self.entries + 1
  end
end

function FileHistoryPanel:set_file_by_offset(offset)
  if self:num_items() == 0 then return end

  local entry, file = self.cur_item[1], self.cur_item[2]

  if not (entry and file) and self:num_items() > 0 then
    self:set_cur_item({ self.entries[1], self.entries[1].files[1] })
    return self.cur_item[2]
  end

  if self:num_items() > 1 then
    local entry_idx = utils.vec_indexof(self.entries, entry)
    local file_idx = utils.vec_indexof(entry.files, file)

    if entry_idx ~= -1 and file_idx ~= -1 then
      local next_entry, next_file = self:_get_entry_by_file_offset(entry_idx, file_idx, offset)
      self:set_cur_item({ next_entry, next_file })

      if next_entry ~= entry then
        self:set_entry_fold(entry, false)
      end

      return self.cur_item[2]
    end
  else
    self:set_cur_item({ self.entries[1], self.entries[1].files[1] })
    return self.cur_item[2]
  end
end

function FileHistoryPanel:prev_file()
  return self:set_file_by_offset(-vim.v.count1)
end

function FileHistoryPanel:next_file()
  return self:set_file_by_offset(vim.v.count1)
end

---@param item LogEntry|FileEntry
function FileHistoryPanel:highlight_item(item)
  if not (self:is_open() and self:buf_loaded()) then return end

  if item:instanceof(LogEntry.__get()) then
    ---@cast item LogEntry
    for _, comp_struct in ipairs(self.components.log.entries) do
      if comp_struct.comp.context == item then
        pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart, 0 })
      end
    end
  else
    ---@cast item FileEntry
    for _, comp_struct in ipairs(self.components.log.entries) do
      local i = utils.vec_indexof(comp_struct.comp.context.files, item)

      if i ~= -1 then
        if self.single_file then
          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + 1, 0 })
        else
          if comp_struct.comp.context.folded then
            comp_struct.comp.context.folded = false
            self:render()
            self:redraw()
          end

          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + i + 1, 0 })
        end
      end
    end
  end

  -- Needed to update the cursorline highlight when the panel is not focused.
  utils.update_win(self.winid)
end

function FileHistoryPanel:highlight_prev_item()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then return end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, -vim.v.count1),
    0,
  })

  utils.update_win(self.winid)
end

function FileHistoryPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then return end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })

  utils.update_win(self.winid)
end

---@param entry LogEntry
---@param open boolean
function FileHistoryPanel:set_entry_fold(entry, open)
  if not self.single_file and open == entry.folded then
    entry.folded = not open
    self:render()
    self:redraw()

    if entry.folded then
      -- Set the cursor at the top of the log entry
      self.components.log.entries.comp:some(function(comp, _, _)
        if comp.context == entry then
          utils.set_cursor(self.winid, comp.lstart + 1)
          return true
        end
      end)
    end
  end
end

---@param entry LogEntry
function FileHistoryPanel:toggle_entry_fold(entry)
  self:set_entry_fold(entry, entry.folded)
end

function FileHistoryPanel:render()
  perf_render:reset()
  panel_renderer.file_history_panel(self)
  perf_render:time()
  logger:lvl(10):debug(perf_render)
end

---@return LogOptions
function FileHistoryPanel:get_log_options()
  if self.single_file then
    return self.log_options.single_file
  else
    return self.log_options.multi_file
  end
end

M.FileHistoryPanel = FileHistoryPanel
return M
