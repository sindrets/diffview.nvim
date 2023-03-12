local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local GitAdapter = lazy.access("diffview.vcs.adapters.git", "GitAdapter") ---@type GitAdapter|LazyModule

local M = {}

---@class Diff1Inline : Diff1
local Diff1Inline = oop.create_class("Diff1Inline", Diff1)

---@param opt Diff1.init.Opt
function Diff1Inline:init(opt)
  Diff1Inline:super().init(self, opt)
end

function Diff1Inline:gs_update_folds()
  if self.b:is_file_open()
    and self.b.file.adapter:instanceof(GitAdapter.__get())
    and self.b.file.kind ~= "conflicting"
  then
    self.b:gs_update_folds()
  end
end

M.Diff1Inline = Diff1Inline
return M
