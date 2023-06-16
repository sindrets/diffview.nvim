local assert = require("luassert")

local M = {}

---@param a any
---@param b any
function M.smart_same(a, b)
  if a == nil or b == nil then return assert.are.equal(a, b) end
  return assert.are.same(a, b)
end

---@param a any
---@param b any
function M.smart_nsame(a, b)
  if a == nil or b == nil then return assert.are_not.equal(a, b) end
  return assert.are_not.same(a, b)
end

M.git = require("tests.diffview.helpers.git")

return M
