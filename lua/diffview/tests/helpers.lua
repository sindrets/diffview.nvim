local assert = require("luassert")
local async = require("diffview.async")

local await, pawait = async.await, async.pawait

local M = {}

function M.eq(a, b)
  if a == nil or b == nil then return assert.are.equal(a, b) end
  return assert.are.same(a, b)
end

function M.neq(a, b)
  if a == nil or b == nil then return assert.are_not.equal(a, b) end
  return assert.are_not.same(a, b)
end

---@param test_func function
function M.async_test(test_func)
  local afunc = async.void(test_func)

  return function(...)
    local ok, err = pawait(afunc(...))
    await(async.scheduler())

    if not ok then
      error(err)
    end
  end
end

return M
