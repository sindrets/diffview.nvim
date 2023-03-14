local oop = require("diffview.oop")
local utils = require("diffview.utils")
local M = {}

---@class Node : diffview.Object
---@field parent Node
---@field name string
---@field data any
---@field children Node[]
---@field depth integer|nil
local Node = oop.create_class("Node")

---Node constructor
---@param name string
---@param data any|nil
function Node:init(name, data)
  self.name = name
  self.data = data
  self.children = {}

  if self.data then
    self.data._node = self
  end
end

---Adds a child if it doesn not already exist.
---@param child Node
---@return Node
function Node:add_child(child)
  if not self.children[child.name] then
    self.children[child.name] = child
    self.children[#self.children + 1] = child
    child.parent = self
  end

  return self.children[child.name]
end

---@return boolean
function Node:has_children()
  for _ in pairs(self.children) do
    return true
  end

  return false
end

---Compare against another node alphabetically and case-insensitive by node names.
---Directory nodes come before file nodes.
---@param a Node
---@param b Node
---@return boolean true if node a comes before node b
function Node.comparator(a, b)
  if a:has_children() == b:has_children() then
    return string.lower(a.name) < string.lower(b.name)
  else
    return a:has_children()
  end
end

function Node:sort()
  for _, child in ipairs(self.children) do
    child:sort()
  end

  utils.merge_sort(self.children, Node.comparator)
end

---@return boolean
function Node:is_root()
  return not self.parent
end

---@param callback fun(node: Node, i: integer, parent: Node): boolean?
function Node:some(callback)
  for i, child in ipairs(self.children) do
    if callback(child, i, self) then
      return
    end
  end
end

---@param callback fun(node: Node, i: integer, parent: Node): boolean?
function Node:deep_some(callback)
  local function wrap(node, i, parent)
    if callback(node, i, parent) then
      return true
    else
      return node:some(wrap)
    end
  end

  self:some(wrap)
end

---@return Node[]
function Node:leaves()
  local leaves = {}

  self:deep_some(function(node)
    if #node.children == 0 then
      leaves[#leaves + 1] = node
    end
    return false
  end)

  return leaves
end

---@return Node?
function Node:first_leaf()
  if #self.children == 0 then
    return
  end

  local cur = self

  while cur:has_children() do
    cur = cur.children[1]
  end

  return cur
end

---@return Node?
function Node:last_leaf()
  if #self.children == 0 then
    return
  end

  local cur = self

  while cur:has_children() do
    cur = cur.children[#cur.children]
  end

  return cur
end

---@return Node?
function Node:next_leaf()
  if not self.parent then
    return
  end

  local cur = self:has_children() and self:group_parent() or self
  local sibling = cur:next_sibling()

  if sibling then
    if not sibling:has_children() then
      return sibling
    else
      return sibling:first_leaf()
    end
  end
end

---@return Node?
function Node:prev_leaf()
  if not self.parent then
    return
  end

  local cur = self:has_children() and self:group_parent() or self
  local sibling = cur:prev_sibling()

  if sibling then
    if not sibling:has_children() then
      return sibling
    else
      return sibling:last_leaf()
    end
  end
end

---@return Node?
function Node:next_sibling()
  if not self.parent then
    return
  end

  local i = utils.vec_indexof(self.parent.children, self)

  if i > -1 and  i < #self.parent.children then
    return self.parent.children[i + 1]
  end
end

---@return Node?
function Node:prev_sibling()
  if not self.parent then
    return
  end

  local i = utils.vec_indexof(self.parent.children, self)

  if i > 1 and #self.parent.children > 1 then
    return self.parent.children[i - 1]
  end
end

---Get the closest parent that has more than one child, or is a child of the
---root node.
---@return Node?
function Node:group_parent()
  if self:is_root() then
    return
  end

  local cur = self:has_children() and self or self.parent

  while not cur.parent:is_root() and #cur.parent.children == 1 do
    cur = cur.parent
  end

  return cur
end

M.Node = Node

return M
