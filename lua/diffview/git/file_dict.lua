local oop = require("diffview.oop")
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local M = {}

---@class FileDict : Object, { [integer]: FileEntry }
---@field working FileEntry[]
---@field staged FileEntry[]
---@field working_tree FileTree
---@field staged_tree FileTree
local FileDict = oop.create_class("FileDict")

---FileDict constructor.
---@return FileDict
function FileDict:init()
  self.working = {}
  self.staged = {}
  self:update_file_trees()
end

do
  local __index = FileDict.__index
  function FileDict:__index(k)
    if type(k) == "number" then
      if k > #self.working then
        return self.staged[k - #self.working]
      else
        return self.working[k]
      end
    else
      return __index(self, k)
    end
  end
end

function FileDict:update_file_trees()
  self.working_tree = FileTree(self.working)
  self.staged_tree = FileTree(self.staged)
end

function FileDict:len()
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
