local async = require("diffview.async")
local RevType = require("diffview.vcs.rev").RevType
local Window = require("diffview.scene.window").Window
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")

local await = async.await

local M = {}

---@class Diff2 : Layout
---@field a Window
---@field b Window
local Diff2 = oop.create_class("Diff2", Layout)

---@alias Diff2.WindowSymbol "a"|"b"

---@class Diff2.init.Opt
---@field a vcs.File
---@field b vcs.File
---@field winid_a integer
---@field winid_b integer

---@param opt Diff2.init.Opt
function Diff2:init(opt)
  self:super()
  self.a = Window({ file = opt.a, id = opt.winid_a })
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self:use_windows(self.a, self.b)
end

---@param file vcs.File
function Diff2:set_file_a(file)
  self.a:set_file(file)
  file.symbol = "a"
end

---@param file vcs.File
function Diff2:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---@param self Diff2
---@param entry FileEntry
Diff2.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Diff2 ]]
  assert(layout:instanceof(Diff2))

  self:set_file_a(layout.a.file)
  self:set_file_b(layout.b.file)

  if self:is_valid() then
    await(self:open_files())
  end
end)

function Diff2:get_main_win()
  return self.b
end

---@override
---@param rev Rev
---@param status string Git status symbol.
---@param sym Diff2.WindowSymbol
function Diff2.should_null(rev, status, sym)
  assert(sym == "a" or sym == "b")

  if rev.type == RevType.LOCAL then
    return status == "D"

  elseif rev.type == RevType.COMMIT then
    if sym == "a" then
      return vim.tbl_contains({ "?", "A" }, status)
    end

    return false

  elseif rev.type == RevType.STAGE then
    if sym == "a" then
      return vim.tbl_contains({ "?", "A" }, status)
    elseif sym == "b" then
      return status == "D"
    end
  end

  error(("Unexpected state! %s, %s, %s"):format(rev, status, sym))
end

M.Diff2 = Diff2
return M
