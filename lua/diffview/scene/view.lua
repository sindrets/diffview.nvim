local lazy = require("diffview.lazy")

local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") --[[@as Diff2Hor|LazyModule ]]
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") --[[@as Diff2Ver|LazyModule ]]
local EventEmitter = lazy.access("diffview.events", "EventEmitter") --[[@as EventEmitter|LazyModule ]]
local File = lazy.access("diffview.git.file", "File") --[[@as git.File|LazyModule ]]
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

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

  local function wrap_event(event)
    DiffviewGlobal.emitter:on(event, function(view, ...)
      local cur_view = require("diffview.lib").get_current_view()

      if (view and view == self) or (not view and cur_view == self) then
        self.emitter:emit(event, view, ...)
      end
    end)
  end

  wrap_event("view_closed")
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

---@return Diff2
function View.get_default_diff2()
  local diffopts = utils.str_split(vim.o.diffopt, ",")
  if vim.tbl_contains(diffopts, "horizontal") then
    return Diff2Ver.__get()
  else
    return Diff2Hor.__get()
  end
end

function View.get_default_diff3()
  error("Not implemented!")
end

---@return Diff2 # (class) The default layout class.
function View.get_default_layout()
  return View.get_default_diff2()
end

---@return Diff2
function View.get_temp_layout()
  local layout_class = View.get_default_layout()
  return layout_class({
    a = File.NULL_FILE,
    b = File.NULL_FILE,
  })
end

M.LayoutMode = LayoutMode
M.View = View

return M
