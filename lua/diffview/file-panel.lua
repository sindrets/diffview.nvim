local config = require'diffview.config'
local utils = require'diffview.utils'
local renderer = require'diffview.renderer'
local a = vim.api
local M = {}

local name_counter = 1
local header_size = 2

---@class FilePanel
---@field git_root string
---@field files FileEntry[]
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field width integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
local FilePanel = utils.class()

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
  signcolumn = 'yes',
  foldmethod = 'manual',
  foldcolumn = '0',
  scrollbind = false,
  cursorbind = false,
  diff = false,
  winhl = table.concat({
    'EndOfBuffer:DiffviewEndOfBuffer',
    'Normal:DiffviewNormal',
    'CursorLine:DiffviewCursorLine',
    'VertSplit:DiffviewVertSplit',
    'SignColumn:DiffviewNormal',
    'StatusLine:DiffviewStatusLine',
    'StatusLineNC:DiffviewStatuslineNC'
  }, ',')
}

FilePanel.bufopts = {
  swapfile = false,
  buftype = 'nofile';
  modifiable = false;
  filetype = 'DiffviewFiles';
  bufhidden = 'hide';
}

---FilePanel constructor.
---@param git_root string
---@param files FileEntry[]
---@param path_args string[]
---@return FilePanel
function FilePanel:new(git_root, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  local this = {
    git_root = git_root,
    files = files,
    path_args = path_args,
    rev_pretty_name = rev_pretty_name,
    width = conf.file_panel.width
  }
  setmetatable(this, self)
  return this
end

function FilePanel:is_open()
  local valid = self.winid and a.nvim_win_is_valid(self.winid)
  if not valid then self.winid = nil end
  return valid
end

function FilePanel:is_focused()
  return self:is_open() and a.nvim_get_current_win() == self.winid
end

function FilePanel:focus(open_if_closed)
  if self:is_open() then
    a.nvim_set_current_win(self.winid)
  elseif open_if_closed then
    self:open()
  end
end

function FilePanel:open()
  if not self:buf_loaded() then self:init_buffer() end
  if self:is_open() then return end

  local conf = config.get_config()
  self.width = conf.file_panel.width
  vim.cmd("vsp")
  vim.cmd("wincmd H")
  vim.cmd("vertical resize " .. self.width)
  self.winid = a.nvim_get_current_win()

  for k, v in pairs(FilePanel.winopts) do
    a.nvim_win_set_option(self.winid, k, v)
  end

  vim.cmd("buffer " .. self.bufid)
  vim.cmd(":wincmd =")
end

function FilePanel:close()
  if self:is_open() then
    a.nvim_win_hide(self.winid)
  end
end

function FilePanel:destroy()
  if self:buf_loaded() then
    self:close()
    a.nvim_buf_delete(self.bufid, { force = true })
  else
    self:close()
  end
end

function FilePanel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function FilePanel:buf_loaded()
  return self.bufid and a.nvim_buf_is_loaded(self.bufid)
end

function FilePanel:init_buffer()
  local bn = a.nvim_create_buf(false, false)

  for k, v in pairs(FilePanel.bufopts) do
    a.nvim_buf_set_option(bn, k, v)
  end

  local bufname = "DiffviewFiles-" .. name_counter
  name_counter = name_counter + 1
  local ok = pcall(a.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    a.nvim_buf_set_name(bn, bufname)
  end

  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings.file_panel) do
    a.nvim_buf_set_keymap(bn, "n", lhs, rhs, { noremap = true, silent = true })
  end

  self.bufid = bn
  self.render_data = renderer.RenderData:new(bufname)
  self:render()
  self:redraw()

  return bn
end

function FilePanel:get_file_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then return end

  local cursor = a.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  return self.files[utils.clamp(line - header_size, 1, #self.files)]
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then return end

  for i, f in ipairs(self.files) do
    if f == file then
      pcall(a.nvim_win_set_cursor, self.winid, {i + header_size, 0})
    end
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or #self.files == 0 then return end

  local cur = self:get_file_at_cursor()
  for i, f in ipairs(self.files) do
    if f == cur then
      local line = utils.clamp(i + header_size - 1, header_size + 1, #self.files + header_size)
      pcall(a.nvim_win_set_cursor, self.winid, {line, 0})
    end
  end
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.files == 0 then return end

  local cur = self:get_file_at_cursor()
  for i, f in ipairs(self.files) do
    if f == cur then
      local line = utils.clamp(i + header_size + 1, header_size, #self.files + header_size)
      pcall(a.nvim_win_set_cursor, self.winid, {line, 0})
    end
  end
end

function FilePanel:render()
  if not self.render_data then return end

  self.render_data:clear()
  local line_idx = 0
  local lines = self.render_data.lines
  local add_hl = function (...)
    self.render_data:add_hl(...)
  end

  local s = utils.path_shorten(self.git_root, self.width - 6)
  add_hl("DiffviewFilePanelRootPath", line_idx, 0, #s)
  table.insert(lines, s)
  line_idx = line_idx + 1

  s = "Changes"
  add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
  local change_count = "("  .. #self.files .. ")"
  add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
  s =  s .. " " .. change_count
  table.insert(lines, s)
  line_idx = line_idx + 1

  for _, file in ipairs(self.files) do
    local offset = 0

    add_hl(renderer.get_git_hl(file.status), line_idx, 0, 1)
    s = file.status .. " "
    offset = #s
    local icon = renderer.get_file_icon(file.basename, file.extension, self.render_data, line_idx, offset)
    offset = offset + #icon
    add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #file.basename)
    s = s .. icon .. file.basename

    if file.stats then
      offset = #s + 1
      add_hl("DiffviewFilePanelInsertions", line_idx, offset, offset + string.len(file.stats.additions))
      offset = offset + string.len(file.stats.additions) + 2
      add_hl("DiffviewFilePanelDeletions", line_idx, offset, offset + string.len(file.stats.deletions))
      s = s .. " " .. file.stats.additions .. ", " .. file.stats.deletions
    end

    offset = #s + 1
    add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path)
    s = s .. " " .. file.parent_path

    table.insert(lines, s)
    line_idx = line_idx + 1
  end

  if self.rev_pretty_name or (self.path_args and #self.path_args > 0) then
    local extra_info = utils.tbl_concat(
      { self.rev_pretty_name and ("commit " .. self.rev_pretty_name) or nil },
      self.path_args or {}
    )
    table.insert(lines, "")
    line_idx = line_idx + 1

    s = "Showing changes for:"
    add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    table.insert(lines, s)
    line_idx = line_idx + 1

    for _, arg in ipairs(extra_info) do
      local relpath = utils.path_relative(arg, self.git_root)
      if relpath == "" then relpath = "." end
      s = utils.path_shorten(relpath, self.width - 5)
      add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      table.insert(lines, s)
      line_idx = line_idx + 1
    end
  end
end

function FilePanel:redraw()
  if not self.render_data then return end
  renderer.render(self.bufid, self.render_data)
end

M.FilePanel = FilePanel
return M
