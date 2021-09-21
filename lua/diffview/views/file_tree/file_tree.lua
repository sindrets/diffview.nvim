local oop = require("diffview.oop")
local utils = require("diffview.utils")
local Node = require("diffview.views.file_tree.node").Node

local M = {}

---@class FileTree
---@field root Node
local FileTree = oop.Object
FileTree = oop.create_class("FileTree")

---FileTree constructor
---@param files FileEntry[]
---@return FileTree
function FileTree:init(files)
  self.root = Node("")

  for _, file in ipairs(files) do
    self:add_file_entry(file)
  end
end

---@param file FileEntry
function FileTree:add_file_entry(file)
  local parts = utils.path_explode(file.path)
  local cur_node = self.root

  -- Create missing intermediate pathname components
  for i = 1, #parts - 1 do
    local name = parts[i]
    if not cur_node.children[name] then
      cur_node = cur_node:add_child(Node(name))
    else
      cur_node = cur_node.children[name]
    end
  end

  cur_node:add_child(Node(parts[#parts], file))
end

---Lists the nodes in the file tree with depths.
---@return Node[]
function FileTree:list()
  return self.root:children_recursive(0)
end

M.FileTree = FileTree

return M
