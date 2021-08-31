local oop = require("diffview.oop")
local M = {}

---@class FileDict
---@field working FileEntry[]
---@field staged FileEntry[]
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
  return function()
    i = i + 1
    if i <= n then
      ---@type integer, FileEntry
      return i, self[i]
    end
  end
end

M.FileDict = FileDict
return M
