local oop = require("diffview.oop")
local utils = require("diffview.utils")
local Node = require("diffview.views.file_tree.node").Node

local M = {}

---@class FileTree
---@field root Node
local FileTree = oop.Object
FileTree = oop.create_class("FileTree")

---FileTree constructor
---@return FileTree
function FileTree:init()
  self.root = Node("", nil)
end

---@param file FileEntry
function FileTree:add_file_entry(file)
  local parts = utils.path_split(file.path)
  local node = self.root

  for i, basename in ipairs(parts) do
    local is_file = i == #parts

    -- TODO
    local node_data = nil
    if is_file then
      node_data = file
    end

    node = node:add_child(Node(basename, file))
  end
end

---@param file FileEntry[]
function FileTree:add_file_entries(files)
  for _, file in ipairs(files) do
    self:add_file_entry(file)
  end
end

---Lists the nodes in the file tree with depths.
---@return Node[]
function FileTree:list()
  return self.root:children_recursive(0)
end

M.FileTree = FileTree

return M
