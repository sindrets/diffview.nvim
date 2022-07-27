local lazy = require("diffview.lazy")

---@type Diff2
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2")
---@type Panel
local Panel = lazy.access("diffview.ui.panel", "Panel")
---@type View
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
local StandardView = oop.create_class("StandardView", View)

---StandardView constructor
function StandardView:init(opt)
  opt = opt or {}
  StandardView:super().init(self, opt)
  self.nulled = utils.sate(opt.nulled, false)
  self.panel = opt.panel or Panel()
  self.winopts = opt.winopts or { a = {}, b = {} }
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
  print(self.tabpage)

  self:use_layout(StandardView.get_temp_layout())
  self.cur_layout:create()
  vim.t[self.tabpage].diffview_view_initialized = true

  if first_init then
    api.nvim_win_close(curwin, false)
  end

  self.panel:focus()
  self:post_layout()
end

function StandardView:post_layout()
  if config.get_config().enhanced_diff_hl then
    self.winopts.a.winhl = {
      "DiffAdd:DiffviewDiffAddAsDelete",
      "DiffDelete:DiffviewDiffDelete",
    }
    self.winopts.b.winhl = {
      "DiffDelete:DiffviewDiffDelete",
    }
  end
end

function StandardView:update_windows()
  -- FIXME: Window local options should be added to the git.File instances, and
  -- then later set by the Layout through the Window class.

  -- if self.cur_layout and self.cur_layout:is_valid() then
  --   utils.set_local(self.cur_layout.a.id, self.winopts.a)
  --   utils.set_local(self.cur_layout.b.id, self.winopts.b)
  -- end
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
  self.cur_layout = layout

  layout.pivot_producer = function()
    local was_open = self.panel:is_open()
    self.panel:close()

    vim.cmd("1windo aboveleft vsp")
    local pivot = api.nvim_get_current_win()

    if was_open then
      self.panel:open()
    end

    return pivot
  end
end

---@param entry FileEntry
function StandardView:use_entry(entry)
  if entry.layout:instanceof(Diff2) then
    local layout = entry.layout --[[@as Diff2 ]]
    layout.a.file.winopts = vim.tbl_extend("force", layout.a.file.winopts, self.winopts.a or {})
    layout.b.file.winopts = vim.tbl_extend("force", layout.b.file.winopts, self.winopts.b or {})
  end

  if entry.layout:class():path() == self.cur_layout:class():path() then
    self.cur_layout:use_entry(entry)
  else
    local old_layout = self.cur_layout
    self:use_layout(entry.layout)
    self.cur_layout:create()
    old_layout:destroy()
  end
end

M.StandardView = StandardView

return M
