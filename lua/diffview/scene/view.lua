local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local EventEmitter = require("diffview.events").EventEmitter
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local M = {}

---@class LayoutMode

---@class ELayoutMode
---@field HORIZONTAL LayoutMode
---@field VERTICAL LayoutMode
local LayoutMode = oop.enum({
  "HORIZONTAL",
  "VERTICAL",
})

---@class View : diffview.Object
---@field tabpage integer
---@field emitter EventEmitter
---@field default_layout Layout (class)
---@field ready boolean
---@field closing boolean
local View = oop.create_class("View")

---@diagnostic disable unused-local

---@abstract
function View:init_layout() oop.abstract_stub() end

---@abstract
function View:post_open() oop.abstract_stub() end

---@diagnostic enable unused-local

---View constructor
function View:init(opt)
  opt = opt or {}
  self.emitter = opt.emitter or EventEmitter()
  self.default_layout = opt.default_layout or View.get_default_layout()
  self.ready = utils.sate(opt.ready, false)
  self.closing = utils.sate(opt.closing, false)
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = api.nvim_get_current_tabpage()
  self:init_layout()
  self:post_open()
  DiffviewGlobal.emitter:emit("view_opened", self)
  DiffviewGlobal.emitter:emit("view_enter", self)
end

function View:close()
  self.closing = true

  if self.tabpage and api.nvim_tabpage_is_valid(self.tabpage) then
    DiffviewGlobal.emitter:emit("view_leave", self)

    local pagenr = api.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end

  DiffviewGlobal.emitter:emit("view_closed", self)
end

function View:is_cur_tabpage()
  return self.tabpage == api.nvim_get_current_tabpage()
end

---Ensure both left and right windows exist in the view's tabpage.
function View:ensure_layout()
  --FIXME
  local state = self:validate_layout()
  if not state.valid then
    self:recover_layout(state)
  end
end

---@return Diff2 # (class) The default layout class.
function View.get_default_layout()
  local diffopts = utils.str_split(vim.o.diffopt, ",")
  if vim.tbl_contains(diffopts, "horizontal") then
    -- return Diff2Ver
    error("Not implemented!")
  else
    return Diff2Hor
  end
end

M.LayoutMode = LayoutMode
M.View = View

return M
