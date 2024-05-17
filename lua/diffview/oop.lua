local lazy = require("diffview.lazy")
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local fmt = string.format

local M = {}

function M.abstract_stub()
  error("Unimplemented abstract method!")
end

---@generic T
---@param t T
---@return T
function M.enum(t)
  utils.add_reverse_lookup(t)
  return t
end

---Wrap metatable methods to ensure they're called with the instance as `self`.
---@param func function
---@param instance table
---@return function
local function wrap_mt_func(func, instance)
  return function(_, k)
    return func(instance, k)
  end
end

local mt_func_names = {
  "__index",
  "__tostring",
  "__eq",
  "__add",
  "__sub",
  "__mul",
  "__div",
  "__mod",
  "__pow",
  "__unm",
  "__len",
  "__lt",
  "__le",
  "__concat",
  "__newindex",
  "__call",
}

local function new_instance(class, ...)
  local inst = { class = class }
  local mt = { __index = class }

  for _, mt_name in ipairs(mt_func_names) do
    local class_mt_func = class[mt_name]

    if type(class_mt_func) == "function" then
      mt[mt_name] = wrap_mt_func(class_mt_func, inst)
    elseif class_mt_func ~= nil then
      mt[mt_name] = class_mt_func
    end
  end

  local self = setmetatable(inst, mt)
  self:init(...)

  return self
end

local function tostring(class)
  return fmt("<class %s>", class.__name)
end

---@generic T : diffview.Object
---@generic U : diffview.Object
---@param name string
---@param super_class? T
---@return U new_class
function M.create_class(name, super_class)
  super_class = super_class or M.Object

  return setmetatable(
    {
      __name = name,
      super_class = super_class,
    },
    {
      __index = super_class,
      __call = new_instance,
      __tostring = tostring,
    }
  )
end

local function classm_safeguard(x)
  assert(x.class == nil, "Class method should not be invoked from an instance!")
end

local function instancem_safeguard(x)
  assert(type(x.class) == "table", "Instance method must be called from a class instance!")
end

---@class diffview.Object
---@field protected __name string
---@field private __init_caller? table
---@field class table|diffview.Object
---@field super_class table|diffview.Object
local Object = M.create_class("Object")
M.Object = Object

function Object:__tostring()
  return fmt("<a %s>", self.class.__name)
end

-- ### CLASS METHODS ###

---@return string
function Object:name()
  classm_safeguard(self)
  return self.__name
end

---Check if this class is an ancestor of the given instance. `A` is an ancestor
---of `b` if - and only if - `b` is an instance of a subclass of `A`.
---@param other any
---@return boolean
function Object:ancestorof(other)
  classm_safeguard(self)
  if not M.is_instance(other) then return false end

  return other:instanceof(self)
end

---@return string
function Object:classpath()
  classm_safeguard(self)
  local ret = self.__name
  local cur = self.super_class

  while cur do
    ret = cur.__name .. "." .. ret
    cur = cur.super_class
  end

  return ret
end

-- ### INSTANCE METHODS ###

---Call constructor.
function Object:init(...) end

---Call super constructor.
---@param ... any
function Object:super(...)
  instancem_safeguard(self)
  local next_super

  -- Keep track of what class is currently calling the constructor such that we
  -- can avoid loops.
  if self.__init_caller then
    next_super = self.__init_caller.super_class
  else
    next_super = self.super_class
  end

  if not next_super then return end

  self.__init_caller = next_super
  next_super.init(self, ...)
  self.__init_caller = nil
end

---@param other diffview.Object
---@return boolean
function Object:instanceof(other)
  instancem_safeguard(self)
  local cur = self.class

  while cur do
    if cur == other then return true end
    cur = cur.super_class
  end

  return false
end

---@param x any
---@return boolean
function M.is_class(x)
  if type(x) ~= "table" then return false end
  return type(rawget(x, "__name")) == "string" and x.instanceof == Object.instanceof
end

---@param x any
---@return boolean
function M.is_instance(x)
  if type(x) ~= "table" then return false end
  return M.is_class(x.class)
end

---@class Symbol
---@operator call : Symbol
---@field public name? string
---@field public id integer
---@field private _id_counter integer
local Symbol = M.create_class("Symbol")
M.Symbol = Symbol

---@private
Symbol._id_counter = 1

---@param name? string
function Symbol:init(name)
  self.name = name
  self.id = Symbol._id_counter
  Symbol._id_counter = Symbol._id_counter + 1
end

function Symbol:__tostring()
  if self.name then
    return fmt("<Symbol('%s)>", self.name)
  else
    return fmt("<Symbol(#%d)>", self.id)
  end
end

return M
