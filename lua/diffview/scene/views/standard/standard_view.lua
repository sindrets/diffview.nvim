local async = require("diffview.async")
local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel") ---@type Panel|LazyModule
local View = lazy.access("diffview.scene.view", "View") ---@type View|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

---@class StandardView : View
---@field panel Panel
---@field winopts table
---@field nulled boolean
---@field cur_layout Layout
---@field cur_entry FileEntry
---@field layouts table<Layout, Layout>
local StandardView = oop.create_class("StandardView", View.__get())

---StandardView constructor
function StandardView:init(opt)
  opt = opt or {}
  self:super(opt)
  self.nulled = utils.sate(opt.nulled, false)
  self.panel = opt.panel or Panel()
  self.layouts = opt.layouts or {}
  self.winopts = opt.winopts or {
    diff1 = { a = {} },
    diff2 = { a = {}, b = {} },
    diff3 = { a = {}, b = {}, c = {} },
    diff4 = { a = {}, b = {}, c = {}, d = {} },
  }

  self.emitter:on("post_layout", utils.bind(self.post_layout, self))
end

---@override
function StandardView:close()
  self.panel:destroy()
  View.close(self)
end

---@override
function StandardView:init_layout()
  local first_init = not vim.t[self.tabpage].diffview_view_initialized
  local curwin = api.nvim_get_current_win()

  self:use_layout(StandardView.get_temp_layout())
  self.cur_layout:create()
  vim.t[self.tabpage].diffview_view_initialized = true

  if first_init then
    api.nvim_win_close(curwin, false)
  end

  self.panel:focus()
  self.emitter:emit("post_layout")
end

function StandardView:post_layout()
  if config.get_config().enhanced_diff_hl then
    self.winopts.diff2.a.winhl = {
      "DiffAdd:DiffviewDiffAddAsDelete",
      "DiffDelete:DiffviewDiffDeleteDim",
      "DiffChange:DiffviewDiffChange",
      "DiffText:DiffviewDiffText",
    }
    self.winopts.diff2.b.winhl = {
      "DiffDelete:DiffviewDiffDeleteDim",
      "DiffAdd:DiffviewDiffAdd",
      "DiffChange:DiffviewDiffChange",
      "DiffText:DiffviewDiffText",
    }
  end

  DiffviewGlobal.emitter:emit("view_post_layout", self)
end

---@override
---Ensure both left and right windows exist in the view's tabpage.
function StandardView:ensure_layout()
  if self.cur_layout then
    self.cur_layout:ensure()
  else
    self:init_layout()
  end
end

---@param layout Layout
function StandardView:use_layout(layout)
  self.cur_layout = layout:clone()
  self.layouts[layout.class] = self.cur_layout

  self.cur_layout.pivot_producer = function()
    local was_open = self.panel:is_open()
    local was_only_win = was_open and #utils.tabpage_list_normal_wins(self.tabpage) == 1
    self.panel:close()

    -- If the panel was the only window before closing, then a temp window was
    -- already created by `Panel:close()`.
    if not was_only_win then
      vim.cmd("1windo aboveleft vsp")
    end

    local pivot = api.nvim_get_current_win()

    if was_open then
      self.panel:open()
    end

    return pivot
  end
end

---@param self StandardView
---@param entry FileEntry
StandardView.use_entry = async.void(function(self, entry)
  local layout_key

  if entry.layout:instanceof(Diff1.__get()) then
    layout_key = "diff1"
  elseif entry.layout:instanceof(Diff2.__get()) then
    layout_key = "diff2"
  elseif entry.layout:instanceof(Diff3.__get()) then
    layout_key = "diff3"
  elseif entry.layout:instanceof(Diff4.__get()) then
    layout_key = "diff4"
  end

  for _, sym in ipairs({ "a", "b", "c", "d" }) do
    if entry.layout[sym] then
      entry.layout[sym].file.winopts = vim.tbl_extend(
        "force",
        entry.layout[sym].file.winopts,
        self.winopts[layout_key][sym] or {}
      )
    end
  end

  local old_layout = self.cur_layout
  self.cur_entry = entry

  if entry.layout.class == self.cur_layout.class then
    self.cur_layout.emitter = entry.layout.emitter
    await(self.cur_layout:use_entry(entry))
  else
    if self.layouts[entry.layout.class] then
      self.cur_layout = self.layouts[entry.layout.class]
      self.cur_layout.emitter = entry.layout.emitter
    else
      self:use_layout(entry.layout)
      self.cur_layout.emitter = entry.layout.emitter
    end

    await(self.cur_layout:use_entry(entry))
    local future = self.cur_layout:create()
    old_layout:destroy()

    -- Wait for files to be created + opened
    await(future)

    if not vim.o.equalalways then
      vim.cmd("wincmd =")
    end

    if self.cur_layout:is_focused() then
      self.cur_layout:get_main_win():focus()
    end
  end
end)

M.StandardView = StandardView

return M
