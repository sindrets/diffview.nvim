local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local M = {}

---@class Diff1Inline : Diff1
local Diff1Inline = oop.create_class("Diff1Inline", Diff1)

---@param opt Diff1.init.Opt
function Diff1Inline:init(opt)
  Diff1Inline:super().init(self, opt)
end

M.Diff1Inline = Diff1Inline
return M
