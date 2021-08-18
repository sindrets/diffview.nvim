local oop = require("diffview.oop")
local utils = require("diffview.utils")
local EventEmitter = require("diffview.events").EventEmitter
local a = vim.api

local M = {}

---@class LayoutMode

---@class ELayoutMode
---@field HORIZONTAL LayoutMode
---@field VERTICAL LayoutMode
local LayoutMode = oop.enum({
  "HORIZONTAL",
  "VERTICAL",
})

---@class View
---@field tabpage integer
---@field emitter EventEmitter
---@field layout_mode LayoutMode
---@field ready boolean
---@field init_layout function Abstract
---@field validate_layout function Abstract
---@field recover_layout function Abstract
local View = oop.Object
View = oop.create_class("View")

---View constructor
---@return View
function View:init()
  self.emitter = EventEmitter()
  self.layout_mode = View.get_layout_mode()
  self.ready = false
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = a.nvim_get_current_tabpage()
  self:init_layout()
  self.ready = true
end

function View:close()
  if self.tabpage and a.nvim_tabpage_is_valid(self.tabpage) then
    local pagenr = a.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end
end

View:virtual("init_layout")
View:virtual("validate_layout")
View:virtual("recover_layout")

---Ensure both left and right windows exist in the view's tabpage.
function View:ensure_layout()
  local state = self:validate_layout()
  if not state.valid then
    self:recover_layout(state)
  end
end

function View.get_layout_mode()
  local diffopts = utils.str_split(vim.o.diffopt, ",")
  if vim.tbl_contains(diffopts, "horizontal") then
    return LayoutMode.VERTICAL
  else
    return LayoutMode.HORIZONTAL
  end
end

M.LayoutMode = LayoutMode
M.View = View

return M
