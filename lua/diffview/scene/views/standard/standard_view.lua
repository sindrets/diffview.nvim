local FileEntry = require("diffview.scene.file_entry").FileEntry
local Panel = require("diffview.ui.panel").Panel
local Rev = require("diffview.git.rev").Rev
local View = require("diffview.scene.view").View
local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local M = {}

---@class StandardView : View
---@field panel Panel
---@field winopts table
---@field nulled boolean
---@field cur_layout Diff2
local StandardView = oop.create_class("StandardView", View)

StandardView.null_file = FileEntry.for_d2(StandardView.get_default_layout(), {
  git_ctx = {
    toplevel = "diffview://",
  },
  path = "null",
  kind = "working",
  status = "X",
  nulled = true,
  rev_a = Rev.new_null_tree(),
  rev_b = Rev.new_null_tree(),
})

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
  ---@type Diff2
  self.cur_layout = StandardView.null_file.layout
  StandardView.null_file.layout:create(api.nvim_get_current_win())
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
  if self.cur_layout and self.cur_layout:is_valid() then
    utils.set_local(self.cur_layout.a.id, self.winopts.a)
    utils.set_local(self.cur_layout.b.id, self.winopts.b)
  end
end

---@override
---Ensure both left and right windows exist in the view's tabpage.
function StandardView:ensure_layout()
  if self.cur_layout then
    self.cur_layout:ensure()
  else
    -- FIXME: Probably need to ensure a good pivot here before init.
    self:init_layout()
  end
end

M.StandardView = StandardView

return M
