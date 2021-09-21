local config = require("diffview.config")
local oop = require("diffview.oop")
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
---@field listing_style '"list"'|'"tree"'
---@field render_data RenderData
---@field components CompStruct
---@field constrain_cursor function
local FilePanel = Panel
FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = vim.tbl_extend("force", Panel.winopts, {
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

FilePanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFiles",
})

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
  self.listing_style = conf.file_panel.listing_style
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
  local working_files
  local staged_files

  if self.listing_style == "list" then
    working_files = { name = "files" }
    staged_files = { name = "files" }
    for _, file in ipairs(self.files.working) do
      table.insert(working_files, {
        name = "file",
        context = file,
      })
    end
    for _, file in ipairs(self.files.staged) do
      table.insert(staged_files, {
        name = "file",
        context = file,
      })
    end
  else
    -- tree
    working_files = {
      name = "files",
      unpack(self.files.working_tree:create_comp_schema())
    }
    staged_files = {
      name = "files",
      unpack(self.files.staged_tree:create_comp_schema())
    }
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "working",
      { name = "title" },
      working_files,
    },
    {
      name = "staged",
      { name = "title" },
      staged_files,
    },
    {
      name = "info",
      { name = "title" },
      { name = "entries" },
    },
  })

  self.constrain_cursor = renderer.create_cursor_constraint({
    self.components.working.files.comp,
    self.components.staged.files.comp,
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

  pcall(api.nvim_win_set_cursor, self.winid, { self.constrain_cursor(self.winid, -1), 0 })
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:size() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, { self.constrain_cursor(self.winid, 1), 0 })
end

function FilePanel:render()
  require("diffview.views.diff.render")(self)
end

M.FilePanel = FilePanel
return M
