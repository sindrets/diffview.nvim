local Window = require("diffview.scene.window").Window
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

---@class Diff3 : Layout
---@field a Window
---@field b Window
---@field c Window
local Diff3 = oop.create_class("Diff3", Layout)

---@alias Diff3.WindowSymbol "a"|"b"|"c"

---@class Diff3.init.Opt
---@field a git.File
---@field b git.File
---@field c git.File
---@field winid_a integer
---@field winid_b integer
---@field winid_c integer

---@param opt Diff3.init.Opt
function Diff3:init(opt)
  Diff3:super().init(self)
  self.a = Window({ file = opt.a, id = opt.winid_a })
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self.c = Window({ file = opt.c, id = opt.winid_c })
  utils.vec_push(self.windows, self.a, self.b, self.c)
end

---@param file git.File
function Diff3:set_file_a(file)
  self.a:set_file(file)
  file.symbol = "a"
end

---@param file git.File
function Diff3:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---@param file git.File
function Diff3:set_file_c(file)
  self.c:set_file(file)
  file.symbol = "c"
end

---@param entry FileEntry
function Diff3:use_entry(entry)
  local layout = entry.layout --[[@as Diff3 ]]
  assert(layout:instanceof(Diff3))

  self:set_file_a(layout.a.file)
  self:set_file_b(layout.b.file)
  self:set_file_c(layout.c.file)

  if self:is_valid() then
    self:open_files()
  end
end

function Diff3:get_main_win()
  return self.b
end

---FIXME
---@override
---@param rev Rev
---@param status string Git status symbol.
---@param sym Diff3.WindowSymbol
function Diff3.should_null(rev, status, sym)
  return false
end

M.Diff3 = Diff3
return M
