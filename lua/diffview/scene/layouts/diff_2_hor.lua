local async = require("diffview.async")
local Window = require("diffview.scene.window").Window
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local oop = require("diffview.oop")

local api = vim.api
local await = async.await

local M = {}

---@class Diff2Hor : Diff2
local Diff2Hor = oop.create_class("Diff2Hor", Diff2)

Diff2Hor.name = "diff2_horizontal"

---@class Diff2Hor.init.Opt
---@field a vcs.File
---@field b vcs.File
---@field winid_a integer
---@field winid_b integer

---@param opt Diff2Hor.init.Opt
function Diff2Hor:init(opt)
  self:super(opt)
end

---@override
---@param self Diff2Hor
---@param pivot integer?
Diff2Hor.create = async.void(function(self, pivot)
  self:create_pre()
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.a then
      self.a:set_id(curwin)
    else
      self.a = Window({ id = curwin })
    end
  end)

  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.b then
      self.b:set_id(curwin)
    else
      self.b = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)
  self.windows = { self.a, self.b }
  await(self:create_post())
end)

M.Diff2Hor = Diff2Hor
return M
