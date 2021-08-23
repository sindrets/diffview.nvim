local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local renderer = require("diffview.renderer")
local Panel = require("diffview.ui.panel").Panel
local Form = require("diffview.ui.panel").Form
local RevType = require("diffview.rev").RevType
local api = vim.api
local M = {}

---@class FileHistoryPanel
---@field git_root string
---@field files FileDict
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
---@param files FileEntry[]
---@return FileHistoryPanel
function FileHistoryPanel:init(git_root, files)
  local conf = config.get_config()
  FileHistoryPanel:super().init(self, {
    position = "bottom",
    width = conf.file_panel.width,
    height = conf.file_panel.height,
  })
  self.git_root = git_root
  self.files = files
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
  for lhs, rhs in pairs(conf.key_bindings.file_panel) do
    api.nvim_buf_set_keymap(bn, "n", lhs, rhs, { noremap = true, silent = true })
  end

  self.bufid = bn
  self.render_data = renderer.RenderData(bufname)

  self.components = {
    ---@type any
    path = self.render_data:create_component({}),
    ---@type any
    working = self.render_data:create_component({
      { name = "title" },
      { name = "entries" },
    }),
  }

  self:render()
  self:redraw()

  return bn
end

---Get the file entry under the cursor.
---@return FileEntry|nil
function FileHistoryPanel:get_file_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  return self.files.working[line - self.components.working.entries.comp.lstart]
end

function FileHistoryPanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  for i, f in self.files:ipairs() do
    if f == file then
      local offset = self.components.working.entries.comp.lstart
      pcall(api.nvim_win_set_cursor, self.winid, { i + offset, 0 })
    end
  end
end

function FileHistoryPanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:size() == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min = self.components.working.entries.comp.lstart + 1
  local max = self.components.working.entries.comp.lend

  line = utils.clamp(line - 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

function FileHistoryPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:size() == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min = self.components.working.entries.comp.lstart + 1
  local max = self.components.working.entries.comp.lend

  line = utils.clamp(line + 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

---@param comp RenderComponent
---@param files FileEntry[]
local function render_entries(comp, files)
  local line_idx = 0

  for _, file in ipairs(files) do
    local offset = 0

    comp:add_hl(renderer.get_git_hl(file.status), line_idx, 0, 1)
    local s = file.status

    if file.stats then
      offset = #s + 1
      local adds = tostring(file.stats.additions)
      if #adds % 3 ~= 0 then
        adds = utils.str_left_pad(adds, #adds + (3 - #adds % 3))
      end
      comp:add_hl(
        "DiffviewFilePanelInsertions",
        line_idx,
        offset,
        offset + #adds
      )
      offset = offset + #adds + 2

      local dels = tostring(file.stats.deletions)
      if #dels % 3 ~= 0 then
        dels = utils.str_left_pad(dels, #dels + (3 - #dels % 3))
      end
      comp:add_hl(
        "DiffviewFilePanelDeletions",
        line_idx,
        offset,
        offset + #dels
      )
      s = s .. " " .. adds .. ", " .. dels
    end

    offset = #s + 1
    local subject = file.right.type == RevType.LOCAL
      and "[Not Committed Yet]" or utils.str_shorten(file.commit.subject, 70)
    comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #subject)
    s = s .. " " .. subject

    offset = #s + 1
    if file.commit then
      local date = (
        -- 3 months
        os.difftime(os.time(), file.commit.time) > 60 * 60 * 24 * 30 * 3
        and file.commit.iso_date
        or file.commit.rel_date
      )
      local info = file.commit.author .. ", " .. date
      comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #info)
      s = s .. " " .. info
    end

    comp:add_line(s)
    line_idx = line_idx + 1
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

  if self.files:size() > 0 then
    local file = self.files.working[1]

    -- file path
    local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, 0)
    local offset = #icon
    comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path + 1)
    comp:add_hl(
      "DiffviewFilePanelFileName",
      line_idx,
      offset + #file.parent_path + 1,
      offset + #file.basename
    )
    s = icon .. file.path
    comp:add_line(s)
    line_idx = line_idx + 1

    -- title
    comp = self.components.working.title.comp
    comp:add_line("")
    line_idx = 1
    s = "File History"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    local change_count = "(" .. #self.files.working .. ")"
    comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
    s = s .. " " .. change_count
    comp:add_line(s)

    render_entries(self.components.working.entries.comp, self.files.working)
  end
end

M.FileHistoryPanel = FileHistoryPanel
return M
