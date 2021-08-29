local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local renderer = require("diffview.renderer")
local Panel = require("diffview.ui.panel").Panel
local api = vim.api
local M = {}

---@class FilePanel
---@field git_root string
---@field files FileDict
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field width integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field components any
local FilePanel = Panel
FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = {
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

FilePanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "DiffviewFiles",
  bufhidden = "hide",
}

---FilePanel constructor.
---@param git_root string
---@param files FileEntry[]
---@param path_args string[]
---@return FilePanel
function FilePanel:init(git_root, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  FilePanel:super().init(self, {
    position = conf.file_panel.position,
    width = conf.file_panel.width,
    height = conf.file_panel.height,
    bufname = "DiffviewFilePanel",
  })
  self.git_root = git_root
  self.files = files
  self.path_args = path_args
  self.rev_pretty_name = rev_pretty_name
end

---@Override
function FilePanel:open()
  FilePanel:super().open(self)
  vim.cmd("wincmd =")
end

function FilePanel:init_buffer_opts()
  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings.file_panel) do
    api.nvim_buf_set_keymap(self.bufid, "n", lhs, rhs, { noremap = true, silent = true })
  end
end

function FilePanel:update_components()
  ---@type any
  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "working",
      { name = "title" },
      { name = "files" }
    },
    {
      name = "staged",
      { name = "title" },
      { name = "files" }
    },
    {
      name = "info",
      { name = "title" },
      { name = "entries" }
    },
  })
end

---Get the file entry under the cursor.
---@return FileEntry|nil
function FilePanel:get_file_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  if line > self.components.working.files.comp.lend then
    return self.files.staged[line - self.components.staged.files.comp.lstart]
  else
    return self.files.working[line - self.components.working.files.comp.lstart]
  end
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  for i, f in self.files:ipairs() do
    if f == file then
      local offset
      if i > #self.files.working then
        i = i - #self.files.working
        offset = self.components.staged.files.comp.lstart
      else
        offset = self.components.working.files.comp.lstart
      end
      pcall(api.nvim_win_set_cursor, self.winid, { i + offset, 0 })
    end
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:size() == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min, max

  if #self.files.working == 0 or line - 1 > self.components.staged.files.comp.lstart then
    min = self.components.staged.files.comp.lstart + 1
    max = self.components.staged.files.comp.lend
  else
    min = self.components.working.files.comp.lstart + 1
    max = self.components.working.files.comp.lend
  end

  line = utils.clamp(line - 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:size() == 0 then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local min, max

  if #self.files.working == 0 or line + 1 > self.components.working.files.comp.lend then
    min = self.components.staged.files.comp.lstart + 1
    max = self.components.staged.files.comp.lend
  else
    min = self.components.working.files.comp.lstart + 1
    max = self.components.working.files.comp.lend
  end

  line = utils.clamp(line + 1, min, max)
  pcall(api.nvim_win_set_cursor, self.winid, { line, 0 })
end

---@param comp RenderComponent
---@param files FileEntry[]
local function render_files(comp, files)
  local line_idx = 0

  for _, file in ipairs(files) do
    local offset = 0

    comp:add_hl(renderer.get_git_hl(file.status), line_idx, 0, 1)
    local s = file.status .. " "
    offset = #s
    local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, offset)
    offset = offset + #icon
    comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #file.basename)
    s = s .. icon .. file.basename

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

    offset = #s + 1
    comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path)
    s = s .. " " .. file.parent_path

    comp:add_line(s)
    line_idx = line_idx + 1
  end
end

function FilePanel:render()
  if not self.render_data then
    return
  end

  self.render_data:clear()

  ---@type RenderComponent
  local comp = self.components.path.comp
  local line_idx = 0
  local s = utils.path_shorten(vim.fn.fnamemodify(self.git_root, ":~"), self.width - 6)
  comp:add_hl("DiffviewFilePanelRootPath", line_idx, 0, #s)
  comp:add_line(s)

  comp = self.components.working.title.comp
  line_idx = 0
  s = "Changes"
  comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
  local change_count = "(" .. #self.files.working .. ")"
  comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
  s = s .. " " .. change_count
  comp:add_line(s)

  render_files(self.components.working.files.comp, self.files.working)

  if #self.files.staged > 0 then
    comp = self.components.staged.title.comp
    line_idx = 0
    comp:add_line("")
    line_idx = line_idx + 1
    s = "Staged changes"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    change_count = "(" .. #self.files.staged .. ")"
    comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
    s = s .. " " .. change_count
    comp:add_line(s)

    render_files(self.components.staged.files.comp, self.files.staged)
  end

  if self.rev_pretty_name or (self.path_args and #self.path_args > 0) then
    local extra_info = utils.tbl_concat({ self.rev_pretty_name }, self.path_args or {})

    comp = self.components.info.title.comp
    line_idx = 0
    comp:add_line("")
    line_idx = line_idx + 1

    s = "Showing changes for:"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    comp:add_line(s)

    comp = self.components.info.entries.comp
    line_idx = 0
    for _, arg in ipairs(extra_info) do
      local relpath = utils.path_relative(arg, self.git_root)
      if relpath == "" then
        relpath = "."
      end
      s = utils.path_shorten(relpath, self.width - 5)
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      comp:add_line(s)
      line_idx = line_idx + 1
    end
  end
end

M.FilePanel = FilePanel
return M
