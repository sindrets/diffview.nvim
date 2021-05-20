local utils = require'diffview.utils'
local M = {}

---@class RevType

---@class ERevType
---@field LOCAL RevType
---@field COMMIT RevType
---@field CUSTOM RevType
local RevType = utils.enum {
  "LOCAL",
  "COMMIT",
  "CUSTOM"
}

---@class Rev
---@field type integer
---@field commit string A commit SHA.
---@field head boolean If true, indicates that the rev should be updated when HEAD changes.
local Rev = utils.class()

---Rev constructor
---@param type RevType
---@param commit string
---@param head boolean
---@return Rev
function Rev:new(type, commit, head)
  local this = {
    type = type,
    commit = commit,
    head = head or false
  }
  setmetatable(this, self)
  return this
end

---Get an abbreviated commit SHA. Returns `nil` if this Rev is not a commit.
---@return string|nil
function Rev:abbrev()
  if self.commit then
    return self.commit:sub(1, 7)
  end
  return nil
end

M.RevType = RevType
M.Rev = Rev

return M
