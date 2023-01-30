local lazy = require("diffview.lazy")

---@type Diff1|LazyModule
local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1")
---@type Diff2|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2")
---@type Diff3|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3")
---@type Diff4|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_3", "Diff4")
---@type Panel|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel")
---@type View|LazyModule
local View = lazy.access("diffview.scene.view", "View")
---@module "diffview.config"
local config = lazy.require("diffview.config")
---@module "diffview.oop"
local oop = lazy.require("diffview.oop")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local api = vim.api
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
  StandardView:super().init(self, opt)
  self.nulled = utils.sate(opt.nulled, false)
  self.panel = opt.panel or Panel()
  self.layouts = opt.layouts or {}
  self.winopts = opt.winopts or {
    diff1 = { a = {} },
    diff2 = { a = {}, b = {} },
    diff3 = { a = {}, b = {}, c = {} },
    diff4 = { a = {}, b = {}, c = {}, d = {} },
  }

  self.emitter:on("post_layout", utils.wrap_call(self.post_layout, self))
end

---@override
function StandardView:close()
  self.closing = true
  self.panel:destroy()

  if self.tabpage and api.nvim_tabpage_is_valid(self.tabpage) then
    DiffviewGlobal.emitter:emit("view_leave", self)

    local pagenr = api.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end

  DiffviewGlobal.emitter:emit("view_closed", self)
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
      "DiffDelete:DiffviewDiffDelete",
    }
    self.winopts.diff2.b.winhl = {
      "DiffDelete:DiffviewDiffDelete",
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
  self.layouts[layout:class()] = self.cur_layout

  layout.pivot_producer = function()
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

---@param entry FileEntry
function StandardView:use_entry(entry)
  if entry.layout:instanceof(Diff1.__get()) then
    local layout = entry.layout --[[@as Diff1 ]]
    layout.b.file.winopts = vim.tbl_extend(
      "force",
      layout.b.file.winopts,
      self.winopts.diff1.b or {}
    )

  elseif entry.layout:instanceof(Diff2.__get()) then
    local layout = entry.layout --[[@as Diff2 ]]
    layout.a.file.winopts = vim.tbl_extend(
      "force",
      layout.a.file.winopts,
      self.winopts.diff2.a or {}
    )
    layout.b.file.winopts = vim.tbl_extend(
      "force",
      layout.b.file.winopts,
      self.winopts.diff2.b or {}
    )

  elseif entry.layout:instanceof(Diff3.__get()) then
    local layout = entry.layout --[[@as Diff3 ]]
    layout.a.file.winopts = vim.tbl_extend(
      "force",
      layout.a.file.winopts,
      self.winopts.diff3.a or {}
    )
    layout.b.file.winopts = vim.tbl_extend(
      "force",
      layout.b.file.winopts,
      self.winopts.diff3.b or {}
    )
    layout.c.file.winopts = vim.tbl_extend(
      "force",
      layout.c.file.winopts,
      self.winopts.diff3.c or {}
    )

  elseif entry.layout:instanceof(Diff4.__get()) then
    local layout = entry.layout --[[@as Diff4 ]]
    layout.a.file.winopts = vim.tbl_extend(
      "force",
      layout.a.file.winopts,
      self.winopts.diff4.a or {}
    )
    layout.b.file.winopts = vim.tbl_extend(
      "force",
      layout.b.file.winopts,
      self.winopts.diff4.b or {}
    )
    layout.c.file.winopts = vim.tbl_extend(
      "force",
      layout.c.file.winopts,
      self.winopts.diff4.c or {}
    )
    layout.d.file.winopts = vim.tbl_extend(
      "force",
      layout.d.file.winopts,
      self.winopts.diff4.d or {}
    )
  end

  local old_layout = self.cur_layout

  if entry.layout:class() == self.cur_layout:class() then
    self.cur_layout.emitter = entry.layout.emitter
    self.cur_layout:use_entry(entry)
  else
    if self.layouts[entry.layout:class()] then
      self.cur_layout = self.layouts[entry.layout:class()]
      self.cur_layout.emitter = entry.layout.emitter
      self.cur_layout:use_entry(entry)
    else
      self:use_layout(entry.layout)
      self.cur_layout.emitter = entry.layout.emitter
    end

    self.cur_layout:create()
    old_layout:destroy()

    if not vim.o.equalalways then
      vim.cmd("wincmd =")
    end
  end

  self.cur_entry = entry
end

M.StandardView = StandardView

return M
