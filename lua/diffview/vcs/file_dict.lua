local oop = require("diffview.oop")
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local M = {}

---@alias vcs.FileKind "conflicting"|"working"|"staged"

---@class FileDict : diffview.Object
---@field [integer] FileEntry
---@field sets FileEntry[][]
---@field conflicting FileEntry[]
---@field working FileEntry[]
---@field staged FileEntry[]
---@field conflicting_tree FileTree
---@field working_tree FileTree
---@field staged_tree FileTree
local FileDict = oop.create_class("FileDict")

---FileDict constructor.
function FileDict:init()
  self.conflicting = {}
  self.working = {}
  self.staged = {}
  self.sets = { self.conflicting, self.working, self.staged }
  self:update_file_trees()
end

function FileDict:__index(k)
  if type(k) == "number" then
    local offset = 0

    for _, set in ipairs(self.sets) do
      if k - offset <= #set then
        return set[k - offset]
      end

      offset = offset + #set
    end
  else
    return FileDict[k]
  end
end

function FileDict:update_file_trees()
  -- Save collapsed state from existing trees before recreating them.
  local conflicting_state = self.conflicting_tree and self.conflicting_tree:get_collapsed_state() or {}
  local working_state = self.working_tree and self.working_tree:get_collapsed_state() or {}
  local staged_state = self.staged_tree and self.staged_tree:get_collapsed_state() or {}

  self.conflicting_tree = FileTree(self.conflicting)
  self.working_tree = FileTree(self.working)
  self.staged_tree = FileTree(self.staged)

  -- Restore collapsed state to the new trees.
  self.conflicting_tree:set_collapsed_state(conflicting_state)
  self.working_tree:set_collapsed_state(working_state)
  self.staged_tree:set_collapsed_state(staged_state)
end

function FileDict:len()
  local l = 0
  for _, set in ipairs(self.sets) do l = l + #set end

  return l
end

function FileDict:iter()
  local i = 0
  local n = self:len()

  ---@return integer?, FileEntry?
  return function()
    i = i + 1

    if i <= n then
      return i, self[i]
    end
  end
end

---@param files FileEntry[]
function FileDict:set_conflicting(files)
  for i = 1, math.max(#self.conflicting, #files) do
    self.conflicting[i] = files[i] or nil
  end
end

---@param files FileEntry[]
function FileDict:set_working(files)
  for i = 1, math.max(#self.working, #files) do
    self.working[i] = files[i] or nil
  end
end

---@param files FileEntry[]
function FileDict:set_staged(files)
  for i = 1, math.max(#self.staged, #files) do
    self.staged[i] = files[i] or nil
  end
end

M.FileDict = FileDict
return M
