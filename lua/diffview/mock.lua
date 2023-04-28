--[[
A class for creating mock objects. Accessing any key in the object returns
itself. Calling the object does nothing.
--]]

local M = {}
local mock_mt = {}

local function tbl_clone(t)
  local ret = {}
  for k, v in pairs(t) do ret[k] = v end
  return ret
end

---@class Mock
---@operator call : Mock
local Mock = setmetatable({}, mock_mt)

function mock_mt.__index(_, key)
  return mock_mt[key]
end

function mock_mt.__call(_, internals)
  local mt = {
    __index = function(self, k)
      if Mock[k] then
        return Mock[k]
      else
        return self
      end
    end,
    __call = function()
      return nil
    end,
  }
  local this = setmetatable(tbl_clone(internals or {}), mt)
  return this
end

M.Mock = Mock
return M
