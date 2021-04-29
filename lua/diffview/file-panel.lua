local config = require'diffview.config'
local utils = require'diffview.utils'
local renderer = require'diffview.renderer'
local a = vim.api
local M = {}

local name_counter = 1

---@class FilePanel
---@field files FileEntry[]
---@field bufid integer
---@field winid integer
---@field render_data RenderData
local FilePanel = {}
FilePanel.__index = FilePanel

FilePanel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  signcolumn = 'yes',
  foldmethod = 'manual',
  foldcolumn = '0',
}

FilePanel.bufopts = {
  swapfile = false,
  buftype = 'nofile';
  modifiable = false;
  filetype = 'DiffviewFiles';
  bufhidden = 'hide';
}

---FilePanel constructor.
---@param files FileEntry[]
---@return FilePanel
function FilePanel:new(files)
  local this = {
    files = files,
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
  vim.cmd("vsp")
  vim.cmd("wincmd H")
  vim.cmd("vertical resize " .. conf.file_panel.width)
  self.winid = a.nvim_get_current_win()

  for k, v in pairs(FilePanel.winopts) do
    a.nvim_win_set_option(self.winid, k, v)
  end

  vim.cmd("buffer " .. self.bufid)
  vim.cmd(":wincmd =")
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

  self.bufid = bn
  self.render_data = renderer.RenderData:new(bufname)
  self:render()
  self:redraw()

  return bn
end

function FilePanel:render()
  if not self.render_data then return end

  local line_idx = 0
  local lines = self.render_data.lines
  for _, file in ipairs(self.files) do
    local s = file.status .. " " .. file.basename
    if file.stats then
      s = s .. " +" .. file.stats.additions .. ", -" .. file.stats.deletions
    end

    table.insert(lines, s)
    line_idx = line_idx + 1
  end
end

function FilePanel:redraw()
  if not self.render_data then return end
  renderer.render(self.bufid, self.render_data)
end

M.FilePanel = FilePanel
return M
