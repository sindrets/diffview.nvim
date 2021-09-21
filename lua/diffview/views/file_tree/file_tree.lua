local oop = require("diffview.oop")
local utils = require("diffview.utils")
local Node = require("diffview.views.file_tree.node").Node

local M = {}

---@class FileTree
---@field root Node
local FileTree = oop.Object
FileTree = oop.create_class("FileTree")

---FileTree constructor
---@param files FileEntry[]|nil
---@return FileTree
function FileTree:init(files)
  self.root = Node("", nil)
  if files then
    self:add_file_entries(files)
  end
end

function FileTree:create_comp_schema()
  local schema = {}

  local function recurse(parent, node)
    if node:has_children() then
      local struct = { name = "directory", context = node.data }
      parent[#parent + 1] = struct
      for _, child in ipairs(node.children) do
        recurse(struct, child)
      end
    else
      parent[#parent + 1] = { name = "file", context = node.data }
    end
  end

  for _, node in ipairs(self.root.children) do
    recurse(schema, node)
  end

  return schema
end

---@param file FileEntry
function FileTree:add_file_entry(file)
  local parts = utils.path_explode(file.path)
  local cur_node = self.root

  -- Create missing intermediate pathname components
  for i = 1, #parts - 1 do
    local name = parts[i]
    if not cur_node.children[name] then
      cur_node = cur_node:add_child(Node(name, { collapsed = false, name = name }))
    else
      cur_node = cur_node.children[name]
    end
  end

  cur_node:add_child(Node(parts[#parts], file))
end

---@param files FileEntry[]
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
