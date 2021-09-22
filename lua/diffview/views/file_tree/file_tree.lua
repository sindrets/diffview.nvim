local oop = require("diffview.oop")
local utils = require("diffview.utils")
local Node = require("diffview.views.file_tree.node").Node

local M = {}

---@class DirData
---@field name string
---@field collapsed boolean
---@field status string

---@class FileTree
---@field root Node
local FileTree = oop.Object
FileTree = oop.create_class("FileTree")

---FileTree constructor
---@param files FileEntry[]|nil
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
      ---@type DirData
      local dir_data = {
        name = name,
        collapsed = false,
        status = " ", -- updated later in FileTree:update_statuses()
      }
      cur_node = cur_node:add_child(Node(name, dir_data))
    else
      cur_node = cur_node.children[name]
    end
  end

  cur_node:add_child(Node(parts[#parts], file))
end

---@param a string
---@param b string
---@return string
local function combine_statuses(a, b)
  if a == " " or a == "?" or a == "!" or a == b then
    return b
  end
  return "M"
end

function FileTree:update_statuses()
  ---@return string the node's status
  local function recurse(node)
    if not node:has_children() then
      return node.data.status
    end

    local parent_status = " "
    for _, child in ipairs(node.children) do
      local child_status = recurse(child)
      parent_status = combine_statuses(parent_status, child_status)
    end

    node.data.status = parent_status
    return parent_status
  end

  for _, node in ipairs(self.root.children) do
    recurse(node)
  end
end

---@param flatten_dirs boolean
function FileTree:create_comp_schema(flatten_dirs)
  self.root:sort()
  local schema = {}

  local function recurse(parent, node)
    if not node:has_children() then
      parent[#parent + 1] = { name = "file", context = node.data }
      return
    end

    ---@type DirData
    local dir_data = node.data

    if flatten_dirs then
      while #node.children == 1 and node.children[1]:has_children() do
        ---@type DirData
        local subdir_data = node.children[1].data
        dir_data = {
          name = utils.path_join({ dir_data.name, subdir_data.name }),
          collapsed = dir_data.collapsed and subdir_data.collapsed,
          status = dir_data.status,
        }
        node = node.children[1]
      end
    end

    local struct = {
      name = "wrapper",
      { name = "directory", context = dir_data },
    }
    parent[#parent + 1] = struct

    for _, child in ipairs(node.children) do
      recurse(struct, child)
    end
  end

  for _, node in ipairs(self.root.children) do
    recurse(schema, node)
  end
  return schema
end

M.FileTree = FileTree

return M
