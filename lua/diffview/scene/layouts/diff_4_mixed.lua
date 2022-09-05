local Window = require("diffview.scene.window").Window
local Diff4 = require("diffview.scene.layouts.diff_4").Diff4
local oop = require("diffview.oop")

local api = vim.api
local M = {}

---@class Diff4Mixed : Diff4
---@field a Window
---@field b Window
---@field c Window
---@field d Window
local Diff4Mixed = oop.create_class("Diff4Mixed", Diff4)

function Diff4Mixed:init(opt)
  Diff4Mixed:super().init(self, opt)
end

---@override
---@param pivot integer?
function Diff4Mixed:create(pivot)
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  api.nvim_win_call(pivot, function()
    vim.cmd("belowright sp")
    curwin = api.nvim_get_current_win()

    if self.b then
      self.b:set_id(curwin)
    else
      self.b = Window({ id = curwin })
    end
  end)

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

    if self.d then
      self.d:set_id(curwin)
    else
      self.d = Window({ id = curwin })
    end
  end)

  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.c then
      self.c:set_id(curwin)
    else
      self.c = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)
  self.windows = { self.a, self.b, self.c, self.d }
  self:open_null()
  self:open_files()
end

M.Diff4Mixed = Diff4Mixed
return M
