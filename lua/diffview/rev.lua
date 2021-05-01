local utils = require'diffview.utils'
local M = {}

---@class RevType
---@field LOCAL integer
---@field COMMIT integer
local RevType = utils.enum {
  "LOCAL",
  "COMMIT"
}

---@class Rev
---@field type integer
---@field commit string
---@field head boolean
local Rev = {}
Rev.__index = Rev

---Rev constructor
---@param type RevType
---@param commit string
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

function Rev:abbrev()
  if self.commit then
    return self.commit:sub(1, 7)
  end
  return nil
end

M.RevType = RevType
M.Rev = Rev

return M
