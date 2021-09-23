local oop = require("diffview.oop")
local FileTree = require("diffview.views.file_tree.file_tree").FileTree
local M = {}

---@type table<integer, FileEntry>
---@class FileDict
---@field working FileEntry[]
---@field staged FileEntry[]
---@field working_tree FileTree
---@field staged_tree FileTree
local FileDict = oop.Object
FileDict = oop.create_class("FileDict")

---FileDict constructor.
---@return FileDict
function FileDict:init()
  self.working = {}
  self.staged = {}

  local mt = getmetatable(self)
  local old_index = mt.__index
  mt.__index = function(t, k)
    if type(k) == "number" then
      if k > #t.working then
        return t.staged[k - #t.working]
      else
        return t.working[k]
      end
    else
      return old_index(t, k)
    end
  end
end

function FileDict:update_file_trees()
  self.working_tree = FileTree(self.working)
  self.staged_tree = FileTree(self.staged)
end

function FileDict:size()
  return #self.working + #self.staged
end

function FileDict:iter()
  local i = 0
  local n = #self.working + #self.staged
  return function()
    i = i + 1
    if i <= n then
      return self[i]
    end
  end
end

function FileDict:ipairs()
  local i = 0
  local n = #self.working + #self.staged
  ---@return integer, FileEntry
  return function()
    i = i + 1
    if i <= n then
      return i, self[i]
    end
  end
end

M.FileDict = FileDict
return M
