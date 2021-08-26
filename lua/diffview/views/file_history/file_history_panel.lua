local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local renderer = require("diffview.renderer")
local Panel = require("diffview.ui.panel").Panel
local Form = require("diffview.ui.panel").Form
local RevType = require("diffview.git.rev").RevType
local LogEntry = require("diffview.git.log_entry").LogEntry
local api = vim.api
local M = {}

---@class FileHistoryPanel
---@field git_root string
---@field entries LogEntry[]
---@field path_args string[]
---@field cur_item {[1]: LogEntry, [2]: FileEntry}
---@field single_file boolean
---@field width integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field components any
local FileHistoryPanel = Panel
FileHistoryPanel = oop.create_class("FileHistoryPanel", Panel)

FileHistoryPanel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  cursorline = true,
  signcolumn = "yes",
  colorcolumn = "",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
  winhl = table.concat({
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "VertSplit:DiffviewVertSplit",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  }, ","),
}

FileHistoryPanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "DiffviewFileHistory",
  bufhidden = "hide",
}

---FileHistoryPanel constructor.
---@param git_root string
---@param entries LogEntry[]
---@return FileHistoryPanel
function FileHistoryPanel:init(git_root, entries, path_args)
  local conf = config.get_config()
  FileHistoryPanel:super().init(self, {
    position = conf.file_history_panel.position,
    width = conf.file_history_panel.width,
    height = conf.file_history_panel.height,
  })
  self.git_root = git_root
  self.entries = entries
  self.path_args = path_args
  self.cur_item = {}
  self.single_file = entries[1] and entries[1].single_file
end

---@Override
function FileHistoryPanel:open()
  FileHistoryPanel:super().open(self)
  vim.cmd("wincmd =")
end

---@Override
function FileHistoryPanel:init_buffer()
  local bn = api.nvim_create_buf(false, false)

  for k, v in pairs(FileHistoryPanel.bufopts) do
    api.nvim_buf_set_option(bn, k, v)
  end

  local bufname = string.format("diffview:///panels/%d/DiffviewPanel", Panel.next_uid())
  local ok = pcall(api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    api.nvim_buf_set_name(bn, bufname)
  end

  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings.file_history_panel) do
    api.nvim_buf_set_keymap(bn, "n", lhs, rhs, { noremap = true, silent = true })
  end

  self.bufid = bn
  self.render_data = renderer.RenderData(bufname)

  self:update_components()
  self:render()
  self:redraw()

  return bn
end

function FileHistoryPanel:update_components()
  local entry_schema = {}
  for _, entry in ipairs(self.entries) do
    table.insert(
      entry_schema,
      {
        name = "entry",
        context = entry,
        { name = "commit" },
        { name = "files" }
      }
    )
  end

  ---@type any
  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "log",
      { name = "title" },
      { name = "entries", unpack(entry_schema) },
    },
  })
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
      if file_idx == #entry.files and #self.entries > 1 then
        -- go to prev entry
        local next_entry_idx = (entry_idx - 2) % #self.entries + 1
        self.cur_item = { self.entries[next_entry_idx], self.entries[next_entry_idx].files[1] }
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
  if not self.single_file then
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

---@param comp RenderComponent
---@param files FileEntry[]
local function render_files(comp, files)
  local line_idx = 0

  for i, file in ipairs(files) do
    local s
    if i == #files then
      s = "└   "
    else
      s = "│   "
    end
    comp:add_hl("DiffviewNonText", line_idx, 0, #s)

    local offset = #s
    comp:add_hl(renderer.get_git_hl(file.status), line_idx, offset, offset + 1)
    s = s .. file.status .. " "
    offset = #s
    local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, offset)
    offset = offset + #icon
    comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path + 1)
    comp:add_hl(
      "DiffviewFilePanelFileName",
      line_idx,
      offset + #file.parent_path + 1,
      offset + #file.basename
    )
    s = s .. icon .. file.path

    if file.stats then
      offset = #s + 1
      comp:add_hl(
        "DiffviewFilePanelInsertions",
        line_idx,
        offset,
        offset + string.len(file.stats.additions)
      )
      offset = offset + string.len(file.stats.additions) + 2
      comp:add_hl(
        "DiffviewFilePanelDeletions",
        line_idx,
        offset,
        offset + string.len(file.stats.deletions)
      )
      s = s .. " " .. file.stats.additions .. ", " .. file.stats.deletions
    end

    comp:add_line(s)
    line_idx = line_idx + 1
  end
end

---@param parent any RenderComponent struct
---@param entries LogEntry[]
local function render_entries(parent, entries)
  local c = config.get_config()
  local max_num_files = -1
  for _, entry in ipairs(entries) do
    if #entry.files > max_num_files then
      max_num_files = #entry.files
    end
  end

  for i, entry in ipairs(entries) do
    if not entry.status then
      print(vim.inspect(entry, {depth = 2}))
    end
    local entry_struct = parent[i]
    local line_idx = 0
    local offset = 0

    local comp = entry_struct.commit.comp
    local s = ""
    if not entry.single_file then
      comp:add_hl("CursorLineNr", line_idx, 0, 3)
      s = (entry.folded and c.signs.fold_closed or c.signs.fold_open) .. " "
    end

    offset = #s
    comp:add_hl(renderer.get_git_hl(entry.status), line_idx, offset, offset + 1)
    s = s .. entry.status

    if not entry.single_file then
      offset = #s
      local counter = " " .. utils.str_left_pad(tostring(#entry.files), #tostring(max_num_files))
        .. " files"
      comp:add_hl("DiffviewFilePanelCounter", line_idx, offset, offset + #counter)
      s = s .. counter
    end

    if entry.stats then
      local adds = tostring(entry.stats.additions)
      local dels = tostring(entry.stats.deletions)
      local l = 7
      local w = l - (#adds + #dels)
      if w < 1 then
        l = (#adds + #dels) - ((#adds + #dels) % 2) + 2
        w = l - (#adds + #dels)
      end

      comp:add_hl("DiffviewNonText", line_idx, #s + 1, #s + 2)
      s = s .. " | "
      offset = #s
      comp:add_hl("DiffviewFilePanelInsertions", line_idx, offset, offset + #adds)
      comp:add_hl(
        "DiffviewFilePanelDeletions",
        line_idx,
        offset + #adds + w,
        offset + #adds + w + #dels
      )
      s = s .. adds .. string.rep(" ", w) .. dels .. " |"
      comp:add_hl("DiffviewNonText", line_idx, #s - 1, #s)
    end

    offset = #s + 1
    local subject = entry.files[1].right.type == RevType.LOCAL
      and "[Not Committed Yet]" or utils.str_shorten(entry.commit.subject, 72)
    comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #subject)
    s = s .. " " .. subject

    offset = #s + 1
    if entry.commit then
      local date = (
        -- 3 months
        os.difftime(os.time(), entry.commit.time) > 60 * 60 * 24 * 30 * 3
        and entry.commit.iso_date
        or entry.commit.rel_date
      )
      local info = entry.commit.author .. ", " .. date
      comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #info)
      s = s .. " " .. info
    end

    comp:add_line(s)
    line_idx = line_idx + 1

    if not entry.single_file and not entry.folded then
      render_files(entry_struct.files.comp, entry.files)
    end
  end
end

function FileHistoryPanel:render()
  if not self.render_data then
    return
  end

  self.render_data:clear()

  ---@type RenderComponent
  local comp = self.components.path.comp
  local line_idx = 0

  -- root path
  local s = (
    self.form == Form.COLUMN
    and utils.path_shorten(vim.fn.fnamemodify(self.git_root, ":~"), self.width - 6)
    or vim.fn.fnamemodify(self.git_root, ":~")
  )
  comp:add_hl("DiffviewFilePanelRootPath", line_idx, 0, #s)
  comp:add_line(s)
  line_idx = line_idx + 1

  if #self.entries > 0 then
    local offset
    if self.single_file then
      local file = self.entries[1].files[1]

      -- file path
      local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, 0)
      offset = #icon
      comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path + 1)
      comp:add_hl(
        "DiffviewFilePanelFileName",
        line_idx,
        offset + #file.parent_path + 1,
        offset + #file.basename
        )
      s = icon .. file.path
      comp:add_line(s)
    else
      s = "Showing history for: "
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      offset = #s
      local paths = table.concat(self.path_args, " ")
      comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #paths)
      comp:add_line(s .. paths)
    end

    -- title
    comp = self.components.log.title.comp
    comp:add_line("")
    line_idx = 1
    s = "File History"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    local change_count = "(" .. #self.entries .. ")"
    comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
    s = s .. " " .. change_count
    comp:add_line(s)

    render_entries(self.components.log.entries, self.entries)
  end
end

M.FileHistoryPanel = FileHistoryPanel
return M
