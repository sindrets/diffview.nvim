local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") ---@type Diff2Hor|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") ---@type Diff2Ver|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver") ---@type Diff3Ver|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule
local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local Signal = lazy.access("diffview.control", "Signal") ---@type Signal|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@type string[]? Saved diffopt value before diffview applied overrides.
local saved_diffopt

-- Boolean diffopt flags that can be toggled.
local diffopt_bool_flags = {
  "indent-heuristic", "iwhite", "iwhiteall", "iwhiteeol", "iblank", "icase",
}

---Apply configured diffopt overrides, saving the original value first.
local function apply_diffopt()
  local conf = config.get_config().diffopt
  if not conf or vim.tbl_isempty(conf) then return end

  if not saved_diffopt then
    saved_diffopt = vim.opt.diffopt:get()
  end

  if conf.algorithm then
    -- Remove any existing algorithm:* entry and add the new one.
    vim.opt.diffopt:remove(
      vim.tbl_filter(function(v) return v:match("^algorithm:") end, vim.opt.diffopt:get())
    )
    vim.opt.diffopt:append({ "algorithm:" .. conf.algorithm })
  end

  if conf.context ~= nil then
    vim.opt.diffopt:remove(
      vim.tbl_filter(function(v) return v:match("^context:") end, vim.opt.diffopt:get())
    )
    vim.opt.diffopt:append({ "context:" .. conf.context })
  end

  for _, flag in ipairs(diffopt_bool_flags) do
    -- Convert config key (underscore-separated) to diffopt flag (hyphenated).
    local key = flag:gsub("-", "_")
    if conf[key] ~= nil then
      if conf[key] then
        vim.opt.diffopt:append({ flag })
      else
        vim.opt.diffopt:remove({ flag })
      end
    end
  end
end

---Restore the original diffopt value.
local function restore_diffopt()
  if saved_diffopt then
    vim.opt.diffopt = saved_diffopt
    saved_diffopt = nil
  end
end

---@enum LayoutMode
local LayoutMode = oop.enum({
  HORIZONTAL = 1,
  VERTICAL = 2,
})

---@class View : diffview.Object
---@field tabpage integer
---@field emitter EventEmitter
---@field default_layout Layout (class)
---@field ready boolean
---@field closing Signal
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
  self.closing = utils.sate(opt.closing, Signal())

  local function wrap_event(event)
    DiffviewGlobal.emitter:on(event, function(_, view, ...)
      local cur_view = require("diffview.lib").get_current_view()

      if (view and view == self) or (not view and cur_view == self) then
        self.emitter:emit(event, view, ...)
      end
    end)
  end

  wrap_event("view_closed")

  -- Apply/restore diffopt overrides on tab enter/leave.
  self.emitter:on("tab_enter", function()
    apply_diffopt()
  end)
  self.emitter:on("tab_leave", function()
    restore_diffopt()
  end)
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = api.nvim_get_current_tabpage()
  self:init_layout()
  self:post_open()
  apply_diffopt()
  DiffviewGlobal.emitter:emit("view_opened", self)
  DiffviewGlobal.emitter:emit("view_enter", self)
end

function View:close()
  self.closing:send()

  if self.tabpage and api.nvim_tabpage_is_valid(self.tabpage) then
    DiffviewGlobal.emitter:emit("view_leave", self)
    restore_diffopt()

    if #api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
    end

    local pagenr = api.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end

  DiffviewGlobal.emitter:emit("view_closed", self)
end

function View:is_cur_tabpage()
  return self.tabpage == api.nvim_get_current_tabpage()
end

---@return boolean
local function prefer_horizontal()
  return vim.tbl_contains(vim.opt.diffopt:get(), "vertical")
end

---@return Diff1
function View.get_default_diff1()
  return Diff1.__get()
end

---@return Diff2
function View.get_default_diff2()
  if prefer_horizontal() then
    return Diff2Hor.__get()
  else
    return Diff2Ver.__get()
  end
end

---@return Diff3
function View.get_default_diff3()
  if prefer_horizontal() then
    return Diff3Hor.__get()
  else
    return Diff3Ver.__get()
  end
end

---@return Diff4
function View.get_default_diff4()
  return Diff4Mixed.__get()
end

---@return LayoutName|-1
function View.get_default_layout_name()
  return config.get_config().view.default.layout
end

---@return Layout # (class) The default layout class.
function View.get_default_layout()
  local name = View.get_default_layout_name()

  if name == -1 then
    return View.get_default_diff2()
  end

  return config.name_to_layout(name --[[@as string ]])
end

---@return Layout
function View.get_default_merge_layout()
  local name = config.get_config().view.merge_tool.layout

  if name == -1 then
    return View.get_default_diff3()
  end

  return config.name_to_layout(name)
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
