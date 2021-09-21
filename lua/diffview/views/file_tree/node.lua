local oop = require("diffview.oop")
local utils = require("diffview.utils")
local M = {}

---@class Node
---@field name string
---@field data any
---@field children Node[]
---@field depth integer|nil
local Node = oop.Object
Node = oop.create_class("Node")

---Node constructor
---@param name string
---@param data any|nil
---@return Node
function Node:init(name, data)
  self.name = name
  self.data = data
  self.children = {}
end

---@param a Node
---@param b Node
function Node.comparator(a, b)
  if a:has_children() and not b:has_children() then
    return true
  elseif not a:has_children() and b:has_children() then
    return false
  end
  return a.name < b.name
end

---Adds a child if it doesn not already exist.
---@param child Node
---@return Node
function Node:add_child(child)
  if not self.children[child.name] then
    self.children[child.name] = child
    self.children[#self.children + 1] = child
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

function Node:sort()
  for _, child in ipairs(self.children) do
    child:sort()
  end
  utils.merge_sort(self.children, Node.comparator)
end

---@param callback function(node: Node, i: integer, parent: Node)
function Node:some(callback)
  for i, child in ipairs(self.children) do
    if callback(child, i, self) then
      return
    end
  end
end

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

---Returns an ordered list of children recursively, with their depths, by
---pre-order traversal of the tree.
---@return Node[]
function Node:children_recursive(start_depth)
  local nodes = {}
  local children = vim.tbl_values(self.children)
  utils.merge_sort(children, Node.comparator)

  for _, child in ipairs(children) do
    child.depth = start_depth
    table.insert(nodes, child)

    for _, grandchild in ipairs(child:children_recursive(start_depth + 1)) do
      table.insert(nodes, grandchild)
    end
  end

  return nodes
end

M.Node = Node

return M
