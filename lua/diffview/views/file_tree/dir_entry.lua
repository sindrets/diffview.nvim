local oop = require("diffview.oop")
local M = {}

---@class GitStats
---@field additions integer
---@field deletions integer

---@class DirEntry
---@field name string
---@field status string
---@field stats GitStats
local DirEntry = oop.Object
DirEntry = oop.create_class("DirEntry")

---DirEntry constructor
---@param name string
---@param status string
---@param stats GitStats
---@return DirEntry
function DirEntry:init(name, status, stats)
  self.name = name
  self.status = status
  self.stats = stats
end

M.DirEntry = DirEntry

return M
