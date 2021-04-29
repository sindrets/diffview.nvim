local utils = require'diffview.utils'
local M = {}

---@class RevType
---@field LOCAL integer
---@field COMMIT integer

---@type table<string, integer>
local RevType = utils.enum {
  "LOCAL",
  "COMMIT"
}

---@class Rev
---@field type integer
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
