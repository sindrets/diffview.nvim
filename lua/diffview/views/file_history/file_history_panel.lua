local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local debounce = require("diffview.debounce")
local git = require("diffview.git.utils")
local renderer = require("diffview.renderer")
local logger = require("diffview.logger")
local PerfTimer = require("diffview.perf").PerfTimer
local Panel = require("diffview.ui.panel").Panel
local LogEntry = require("diffview.git.log_entry").LogEntry
local FHOptionPanel = require("diffview.views.file_history.option_panel").FHOptionPanel
local JobStatus = git.JobStatus
local api = vim.api
local M = {}

---@type PerfTimer
local perf_render = PerfTimer("[FileHistoryPanel] render")
---@type PerfTimer
local perf_update = PerfTimer("[FileHistoryPanel] update")

---@class FileHistoryPanel : Panel
---@field parent FileHistoryView
---@field git_root string
---@field entries LogEntry[]
---@field path_args string[]
---@field raw_args string[]
---@field base Rev
---@field rev_range RevRange
---@field log_options ConfigLogOptions
---@field cur_item {[1]: LogEntry, [2]: FileEntry}
---@field single_file boolean
---@field updating boolean
---@field shutdown boolean
---@field render_data RenderData
---@field option_panel FHOptionPanel
---@field option_mapping string
---@field components CompStruct
---@field constrain_cursor function
local FileHistoryPanel = oop.create_class("FileHistoryPanel", Panel)

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

---@class FileHistoryPanelSpec
---@field base Rev

---FileHistoryPanel constructor.
---@param parent FileHistoryView
---@param git_root string
---@param entries LogEntry[]
---@param path_args string[]
---@param log_options LogOptions
---@param opt FileHistoryPanelSpec
---@return FileHistoryPanel
function FileHistoryPanel:init(parent, git_root, entries, path_args, raw_args, log_options, opt)
  local conf = config.get_config()
  FileHistoryPanel:super().init(self, {
    config = conf.file_history_panel.win_config,
    bufname = "DiffviewFileHistoryPanel",
  })
  self.parent = parent
  self.git_root = git_root
  self.entries = entries
  self.path_args = path_args
  self.raw_args = raw_args
  self.base = opt.base
  self.cur_item = {}
  self.single_file = entries[1] and entries[1].single_file
  self.option_panel = FHOptionPanel(self)
  self.log_options = {
    single_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options.single_file,
      log_options
    ),
    multi_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options.multi_file,
      log_options
    ),
  }

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@Override
function FileHistoryPanel:open()
  FileHistoryPanel:super().open(self)
  vim.cmd("wincmd =")
end

---@Override
function FileHistoryPanel:destroy()
  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end
  self.shutdown = true
  self.entries = nil
  self.cur_item = nil
  self.option_panel:destroy()
  self.option_panel = nil
  self.render_data:destroy()
  if self.components then
    renderer.destroy_comp_struct(self.components)
  end
  FileHistoryPanel:super().destroy(self)
end

function FileHistoryPanel:setup_buffer()
  local conf = config.get_config()
  local option_rhs = config.actions.options

  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for key, mapping in pairs(conf.keymaps.file_history_panel) do
    local lhs, rhs
    if type(key) == "number" then
      lhs, rhs = mapping[2], mapping[3]
      local opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = self.bufid })
      vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
    else
      lhs, rhs = key, mapping
      vim.keymap.set("n", key, mapping, default_opt)
    end

    if rhs == option_rhs then
      self.option_mapping = lhs
    end
  end
end

function FileHistoryPanel:update_components()
  self.render_data:destroy()
  if self.components then
    renderer.destroy_comp_struct(self.components)
  end

  local entry_schema = { name = "entries" }
  for i, entry in ipairs(self.entries) do
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

function FileHistoryPanel:update_entries(callback)
  perf_update:reset()
  local c = 0
  local timeout = 64
  local ldt = 0 -- Last draw time
  local lock = false
  local update, finalizer

  update = debounce.throttle_trailing(timeout, true, function(entries, status, msg)
    if status == JobStatus.ERROR then
      self.updating = false
      vim.schedule(function()
        utils.err(utils.vec_join(
          ("Updating file history failed! %s"):format(msg and "Error message:" or ""),
          msg
        ))
        self:render()
        self:redraw()
        callback(nil, JobStatus.ERROR, msg)
      end)

      update:close()
      return

    elseif status == JobStatus.PROGRESS then
      if self.shutdown then
        -- The parent view has closed: shutdown git jobs and clean up.
        finalizer()
        update:close()
        callback(nil, JobStatus.KILLED)
        return
      end

      if #entries <= c or lock then
        return
      end
    end

    lock = true

    vim.schedule(function()
      c = #entries
      if ldt > timeout then
        logger.lvl(10).debug(
          string.format(
            "[FH_PANEL] Rendering is slower than throttle timeout (%.3f ms). Skipping update.",
            ldt
          )
        )
        ldt = ldt - timeout
        lock = false
        return
      end

      local was_empty = #self.entries == 0
      self.entries = utils.vec_slice(entries)

      if was_empty then
        self.single_file = self.entries[1] and self.entries[1].single_file
      end

      if status == JobStatus.SUCCESS then self.updating = false end

      if not (status == JobStatus.PROGRESS and not self.parent:is_cur_tabpage()) then
        self:sync()
        ldt = renderer.last_draw_time
      end

      if status == JobStatus.SUCCESS then
        update:close()
        perf_update:time()
        logger.s_info(string.format(
          "[FileHistory] Completed update for %d entries successfully (%.3f ms).",
          #self.entries,
          perf_update.final_time
        ))
      end

      if (was_empty or status == JobStatus.SUCCESS) and type(callback) == "function" then
        vim.cmd("redraw")
        callback(entries, status)
      end

      lock = false
    end)
  end)

  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end

  self.cur_item = {}
  self.entries = {}
  self.updating = true
  finalizer = git.file_history(
    self.git_root,
    self.path_args,
    self.log_options,
    { base = self.base, },
    update
  )
  self:sync()
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

function FileHistoryPanel:set_cur_item(new_item)
  if self.cur_item[2] then
    self.cur_item[2]:detach_buffers()
    self.cur_item[2].active = false
  end
  self.cur_item = new_item
  if self.cur_item and self.cur_item[2] then
    self.cur_item[2].active = true
  end
end

function FileHistoryPanel:set_entry_from_file(item)
  local file = self.cur_item[2]
  if item:instanceof(LogEntry) then
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
  if self:num_items() == 0 then
    return
  end
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

function FileHistoryPanel:highlight_item(item)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if item:instanceof(LogEntry) then
    for _, comp_struct in ipairs(self.components.log.entries) do
      if comp_struct.comp.context == item then
        pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart, 0 })
      end
    end
  else
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
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  pcall(
    api.nvim_win_set_cursor,
    self.winid,
    { self.constrain_cursor(self.winid, -vim.v.count1), 0 }
  )
  utils.update_win(self.winid)
end

function FileHistoryPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })
  utils.update_win(self.winid)
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
  perf_render:reset()
  require("diffview.views.file_history.render").file_history_panel(self)
  perf_render:time()
  logger.lvl(10).s_debug(perf_render)
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
