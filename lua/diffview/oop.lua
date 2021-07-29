local M = {}

---Enum creator
---@param t string[]
---@return table<string, integer>
function M.enum(t)
  local enum = {}
  for i, v in ipairs(t) do
    enum[v] = i
  end
  return enum
end

---@class Object -- Base class
local Object = {}
Object.__index = Object

function Object.new()
  return setmetatable({}, Object)
end

function Object:class()
  return Object
end

function Object:super()
  return nil
end

function Object:instanceof(other)
  local cur = self:class()
  while cur do
    if cur == other then
      return true
    end
    cur = cur:super()
  end
  return false
end

function M.class(super_class)
  super_class = super_class or Object
  local new_class = {}
  new_class.__index = new_class

  setmetatable(new_class, super_class)

  function new_class.new()
    return setmetatable({}, new_class)
  end

  ---Get the class object.
  ---@return Object
  function new_class:class()
    return new_class
  end

  ---Get the super class.
  ---@return Object
  function new_class:super()
    return super_class
  end

  return new_class
end

M.Object = Object
return M
