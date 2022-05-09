--[[
  Code derived from: https://github.com/jpatte/yaci.lua
  Original author: Julien Patte [julien.patte@gmail.com]
--]]

local M = {}

---@class EnumValue : integer

---Enum creator
---@param t string[]
---@return table<string, EnumValue>
function M.enum(t)
  local enum = {}
  for i, v in ipairs(t) do
    enum[v] = i
  end
  return enum
end

-- associations between an object an its meta-informations
-- e.g its class, its "lower" object (if any), ...
local meta_obj = setmetatable({}, { __mode = "k" })

--- Return a shallow copy of table t
local function duplicate(t)
  local t2 = {}
  for k, v in pairs(t) do
    t2[k] = v
  end
  return t2
end

---@generic T
---@param class `T`
---@return T
local function new_instance(class, ...)
  ---@diagnostic disable-next-line: redefined-local
  local function make_instance(class, virtuals)
    local inst = duplicate(virtuals)
    inst.__class = class

    if class:super() ~= nil then
      inst.super = make_instance(class:super(), virtuals)
      rawset(inst.super, "__lower", inst)
    else
      inst.super = {}
    end

    setmetatable(inst, class.static)

    return inst
  end

  local inst = make_instance(class, meta_obj[class].virtuals)
  inst:init(...)
  return inst
end

local function make_virtual(class, fname)
  local func = class.static[fname]
  if func == nil then
    func = function()
      error("Attempt to call an undefined abstract method '" .. fname .. "'")
    end
  end
  meta_obj[class].virtuals[fname] = func
end

--- Try to cast an instance into an instance of one of its super- or subclasses
local function try_cast(class, inst)
  if inst.__class == class then
    return inst
  end -- is it already the right class?

  local cur = inst.__lower
  while cur ~= nil do -- search lower in the hierarchy
    if cur.__class == class then
      return cur
    end
    cur = cur.__lower
  end

  cur = inst.super -- not found, search through the superclasses
  while cur ~= nil do
    if cur.__class == class then
      return cur
    end
    cur = cur.super
  end

  return nil -- could not execute casting
end

--- Same as trycast but raise an error in case of failure
local function secure_cast(class, inst)
  local casted = try_cast(class, inst)
  if casted == nil then
    error("Failed to cast " .. tostring(inst) .. " to a " .. class:name())
  end
  return casted
end

local function inst_init_def(inst)
  inst.super:init()
end

local function inst_newindex(inst, key, value)
  -- First check if this field isn't already defined higher in the hierarchy
  if inst.super[key] ~= nil then
    -- Update the old value
    inst.super[key] = value
  else
    -- Create the field
    rawset(inst, key, value)
  end
end

local function subclass(base_class, name)
  if type(name) ~= "string" then
    name = "Unnamed"
  end

  ---@type Object
  local the_class = {}

  -- need to copy everything here because events can't be found through metatables
  local b = base_class.static
  local inst_internals = {
    __tostring = b.__tostring,
    __eq = b.__eq,
    __add = b.__add,
    __sub = b.__sub,
    __mul = b.__mul,
    __div = b.__div,
    __mod = b.__mod,
    __pow = b.__pow,
    __unm = b.__unm,
    __len = b.__len,
    __lt = b.__lt,
    __le = b.__le,
    __concat = b.__concat,
    __call = b.__call,
    __newindex = inst_newindex,
    init = inst_init_def,
    class = function()
      return the_class
    end,
    instanceof = function(_, other)
      return the_class == other or base_class:isa(other)
    end,
  }

  -- Look for field 'key' in instance 'inst'
  function inst_internals.__index(inst, key)
    local res = inst_internals[key]
    if res ~= nil then
      return res
    end

    res = inst.super[key] -- Is it somewhere higher in the hierarchy?

    return res
  end

  local class_internals = {
    static = inst_internals,
    new = new_instance,
    subclass = subclass,
    virtual = make_virtual,
    cast = secure_cast,
    trycast = try_cast,
    name = function(_)
      return name
    end,
    super = function(_)
      return base_class
    end,
    isa = function(_, other)
      return the_class == other or base_class:isa(other)
    end,
  }
  meta_obj[the_class] = { virtuals = duplicate(meta_obj[base_class].virtuals) }

  ---@diagnostic disable-next-line: redefined-local
  local function newmethod(class, name, meth)
    inst_internals[name] = meth
    if meta_obj[class].virtuals[name] ~= nil then
      meta_obj[class].virtuals[name] = meth
    end
  end

  setmetatable(the_class, {
    __index = function(_, key)
      return class_internals[key] or class_internals.static[key] or base_class[key]
    end,
    __tostring = function()
      return "<class " .. name .. ">"
    end,
    __newindex = newmethod,
    __call = new_instance,
  })

  return the_class
end

---@class Object
---@field init function
---@field class function
---@field instanceof function
---@field virtual function
---@field super function
---@field subclass function
local Object = {}

local function obj_newitem()
  error("Do not modify the 'Object' class. Subclass it instead.")
end

local obj_inst_internals = {
  __newindex = obj_newitem,
  __tostring = function(inst)
    return "<a " .. inst:class():name() .. ">"
  end,
  init = function() end,
  class = function()
    return Object
  end,
  instanceof = function(_, other)
    return other == Object
  end,
}
obj_inst_internals.__index = obj_inst_internals

local obj_class_internals = {
  static = obj_inst_internals,
  new = new_instance,
  subclass = subclass,
  cast = secure_cast,
  trycast = try_cast,
  name = function()
    return "Object"
  end,
  super = function()
    return nil
  end,
  isa = function(_, other)
    return other == Object
  end,
}
meta_obj[Object] = { virtuals = {} }

setmetatable(Object, {
  __tostring = function()
    return "<class Object>"
  end,
  __newindex = obj_newitem,
  __index = obj_class_internals,
  __call = new_instance,
})

---Create a new class.
---@generic T : Object
---@param name `T`
---@param super_class? Object
---@return T
function M.create_class(name, super_class)
  super_class = super_class or Object
  return super_class:subclass(name)
end

M.Object = Object
return M
