local oop = require("diffview.oop")
local utils = require("diffview.utils")
local M = {}

---@class Node
---@field name string
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

---Returns an ordered list of children recursively, with their depths, by pre-order traversal of the
---tree.
---@return Node[]
function Node:children_recursive(start_depth)
  local nodes = {}
  local children = vim.tbl_values(self.children)

  utils.merge_sort(children, function(a, b)
    if a:has_children() and not b:has_children() then
      return true
    elseif not a:has_children() and b:has_children() then
      return false
    end
    return a.name < b.name
  end)

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
