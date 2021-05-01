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

M.RevType = RevType
M.Rev = Rev

return M
