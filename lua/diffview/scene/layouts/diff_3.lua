local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Window = require("diffview.scene.window").Window
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local Rev = lazy.access("diffview.vcs.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule

local await = async.await

local M = {}

---@class Diff3 : Layout
---@field a Window
---@field b Window
---@field c Window
local Diff3 = oop.create_class("Diff3", Layout)

---@alias Diff3.WindowSymbol "a"|"b"|"c"

---@class Diff3.init.Opt
---@field a vcs.File
---@field b vcs.File
---@field c vcs.File
---@field winid_a integer
---@field winid_b integer
---@field winid_c integer

---@param opt Diff3.init.Opt
function Diff3:init(opt)
  self:super()
  self.a = Window({ file = opt.a, id = opt.winid_a })
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self.c = Window({ file = opt.c, id = opt.winid_c })
  self:use_windows(self.a, self.b, self.c)
end

---@param file vcs.File
function Diff3:set_file_a(file)
  self.a:set_file(file)
  file.symbol = "a"
end

---@param file vcs.File
function Diff3:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---@param file vcs.File
function Diff3:set_file_c(file)
  self.c:set_file(file)
  file.symbol = "c"
end

---@param self Diff3
---@param entry FileEntry
Diff3.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Diff3 ]]
  assert(layout:instanceof(Diff3))

  self:set_file_a(layout.a.file)
  self:set_file_b(layout.b.file)
  self:set_file_c(layout.c.file)

  if self:is_valid() then
    await(self:open_files())
  end
end)

function Diff3:get_main_win()
  return self.b
end

---@param layout Diff1
---@return Diff1
function Diff3:to_diff1(layout)
  assert(layout:instanceof(Diff1.__get()))

  return layout({ a = self:get_main_win().file })
end

---@param layout Diff4
---@return Diff4
function Diff3:to_diff4(layout)
  assert(layout:instanceof(Diff4.__get()))
  local main = self:get_main_win().file

  return layout({
    a = self.a.file,
    b = self.b.file,
    c = self.c.file,
    d = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 1),
      nulled = false, -- FIXME
    })
  })
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
