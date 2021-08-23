local oop = require("diffview.oop")
local M = {}

---@class RevType

---@class ERevType
---@field LOCAL RevType
---@field COMMIT RevType
---@field INDEX RevType
---@field CUSTOM RevType
local RevType = oop.enum({
  "LOCAL",
  "COMMIT",
  "INDEX",
  "CUSTOM",
})

---@class Rev
---@field type integer
---@field commit string A commit SHA.
---@field head boolean If true, indicates that the rev should be updated when HEAD changes.
local Rev = oop.Object
Rev = oop.create_class("Rev")

---Rev constructor
---@param type RevType
---@param commit string
---@param head boolean
---@return Rev
function Rev:init(type, commit, head)
  self.type = type
  self.commit = commit
  self.head = head or false
end

---Get an abbreviated commit SHA. Returns `nil` if this Rev is not a commit.
---@param length integer|nil
---@return string|nil
function Rev:abbrev(length)
  if self.commit then
    return self.commit:sub(1, length or 7)
  end
  return nil
end

M.RevType = RevType
M.Rev = Rev

return M
