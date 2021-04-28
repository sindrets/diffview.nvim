local utils = require'difftool.utils'
local M = {}

---@class RevType

---@type table<string, RevType>
local RevType = utils.enum {
  "LOCAL",
  "COMMIT"
}

---@class Rev
---@field type RevType
---@field commit string
local Rev = {}
Rev.__index = Rev

---Rev constructor
---@param type RevType
---@param commit string
---@return Rev
function Rev:new(type, commit)
  local this = {
    type = type,
    commit = commit
  }
  setmetatable(this, self)
  return this
end

M.RevType = RevType
M.Rev = Rev

return M
