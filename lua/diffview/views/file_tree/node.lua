local oop = require("diffview.oop")
local utils = require("diffview.utils")
local M = {}

---@class Node
---@field name string
---@field children Node[]
---@field depth integer|nil
---@param data any|nil
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

---Adds a child if it doesn not already exist.
---@param child Node
---@return Node
function Node:add_child(child)
  if self.children[child.name] == nil then
    self.children[child.name] = child
  end
  return self.children[child.name]
end

---@return integer
function Node:count_children()
  local count = 0
  for _ in pairs(self.children) do
    count = count + 1
  end
  return count
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
---
---@param a Node
---@param b Node
---@return true if node a comes before node b
local function compare_nodes(a, b)
  if a:has_children() == b:has_children() then
    return string.lower(a.name) < string.lower(b.name)
  else
    return a:has_children()
  end
end

---Returns a sorted list of children recursively, with their depths.
---@return Node[]
function Node:children_recursive(start_depth)
  local children = {}
  for _, child in pairs(self.children) do
    table.insert(children, child)
  end
  utils.merge_sort(children, compare_nodes)

  local nodes = {}
  for _, child in pairs(children) do
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
