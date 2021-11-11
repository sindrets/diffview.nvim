local oop = require("diffview.oop")
local utils = require("diffview.utils")
local renderer = require("diffview.renderer")
local logger = require("diffview.logger")
local PerfTimer = require("diffview.perf").PerfTimer
local api = vim.api
local M = {}
local uid_counter = 0

---@type PerfTimer
local perf = PerfTimer("[Panel] redraw")

---@class Form

---@class EForm
---@field COLUMN Form
---@field ROW Form
local Form = oop.enum({
  "COLUMN",
  "ROW",
})

---@class Panel : Object
---@field position string
---@field form Form
---@field relative string
---@field width integer
---@field height integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field components any
---@field bufname string
---@field init_buffer_opts function Abstract
---@field update_components function Abstract
---@field render function Abstract
local Panel = oop.create_class("Panel")

Panel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  signcolumn = "yes",
  colorcolumn = "",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
}

Panel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  bufhidden = "hide",
}

function Panel.next_uid()
  local uid = uid_counter
  uid_counter = uid_counter + 1
  return uid
end

function Panel:init(opt)
  self.position = opt.position or "left"
  self.form = vim.tbl_contains({ "top", "bottom" }, self.position) and Form.ROW or Form.COLUMN
  self.relative = opt.relative or "editor"
  self.width = opt.width
  self.height = opt.height
  self.bufname = opt.bufname or "DiffviewPanel"

  local pos = { "left", "top", "right", "bottom" }
  local rel = { "editor", "window" }
  local dim = { "number", "nil" }
  assert(
    vim.tbl_contains(pos, self.position),
    "'position' must be one of: " .. table.concat(pos, ", ")
  )
  assert(
    vim.tbl_contains(rel, self.relative),
    "'relative' must be one of: " .. table.concat(rel, ", ")
  )
  assert(
    vim.tbl_contains(dim, type(self.width)),
    "'width' must be one of: " .. table.concat(dim, ", ")
  )
  assert(
    vim.tbl_contains(dim, type(self.height)),
    "'height' must be one of: " .. table.concat(dim, ", ")
  )
end

function Panel:is_open(in_tabpage)
  local valid = self.winid and api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  elseif in_tabpage then
    return vim.tbl_contains(api.nvim_tabpage_list_wins(0), self.winid)
  end
  return valid
end

function Panel:is_cur_win()
  return self:is_open() and api.nvim_get_current_win() == self.winid
end

function Panel:is_focused()
  return self:is_open() and api.nvim_get_current_win() == self.winid
end

function Panel:focus(open_if_closed)
  if self:is_open() then
    api.nvim_set_current_win(self.winid)
  elseif open_if_closed then
    self:open()
  end
end

function Panel:resize()
  if not self:is_open(true) then
    return
  end

  local cmd
  if self.form == Form.COLUMN and self.width then
    api.nvim_win_set_width(self.winid, self.width)
  elseif self.height then
    api.nvim_win_set_height(self.winid, self.height)
  end

  if cmd then
    vim.cmd(cmd)
  end
end

function Panel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  local split_dir = vim.tbl_contains({ "top", "left" }, self.position) and "aboveleft"
    or "belowright"
  local split_cmd = self.form == Form.ROW and "sp" or "vsp"
  vim.cmd(split_dir .. " " .. split_cmd)

  if self.relative == "editor" then
    local dir = ({ left = "H", bottom = "J", top = "K", right = "L" })[self.position]
    vim.cmd("wincmd " .. dir)
    vim.cmd("wincmd =")
  end

  self.winid = api.nvim_get_current_win()
  self:resize()
  api.nvim_win_set_buf(self.winid, self.bufid)
  utils.set_local(self.winid, self.class().winopts)
end

function Panel:close()
  if self:is_open() then
    api.nvim_win_hide(self.winid)
  end
end

function Panel:destroy()
  self:close()
  if self:buf_loaded() then
    api.nvim_buf_delete(self.bufid, { force = true })
  end
end

function Panel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function Panel:buf_loaded()
  return self.bufid and api.nvim_buf_is_loaded(self.bufid)
end

function Panel:init_buffer()
  local bn = api.nvim_create_buf(false, false)

  local bufname = string.format("diffview:///panels/%d/%s", Panel.next_uid(), self.bufname)
  local ok = pcall(api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    api.nvim_buf_set_name(bn, bufname)
  end

  for k, v in pairs(self.class().bufopts) do
    api.nvim_buf_set_option(bn, k, v)
  end

  self.bufid = bn
  self.render_data = renderer.RenderData(bufname)

  self:init_buffer_opts()
  self:update_components()
  self:render()
  self:redraw()

  return bn
end

Panel:virtual("init_buffer_opts")
Panel:virtual("update_components")
Panel:virtual("render")

function Panel:redraw()
  if not self.render_data then
    return
  end
  perf:reset()
  renderer.render(self.bufid, self.render_data)
  perf:time()
  if DiffviewGlobal.debug_level >= 10 then
    logger.s_debug(perf)
  end
end

M.Form = Form
M.Panel = Panel
return M
