local oop = require("diffview.oop")
local utils = require("diffview.utils")
local EventEmitter = require("diffview.events").EventEmitter
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

---@class View : Object
---@field tabpage integer
---@field emitter EventEmitter
---@field layout_mode LayoutMode
---@field ready boolean
---@field closing boolean
---@field init_layout function Abstract
---@field post_open function Abstract
---@field validate_layout function Abstract
---@field recover_layout function Abstract
local View = oop.create_class("View")

View:virtual("init_layout")
View:virtual("post_open")
View:virtual("validate_layout")
View:virtual("recover_layout")

---View constructor
---@return View
function View:init()
  self.emitter = EventEmitter()
  self.layout_mode = View.get_layout_mode()
  self.ready = false
  self.closing = false
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
