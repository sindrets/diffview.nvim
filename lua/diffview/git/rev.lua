local utils = require("diffview.utils")
local oop = require("diffview.oop")
local M = {}

---@class RevType

---@class ERevType
---@field LOCAL RevType
---@field COMMIT RevType
---@field INDEX RevType
---@field CUSTOM RevType
local RevType = oop.enum({
  "LOCAL",
  "COMMIT",
  "INDEX",
  "CUSTOM",
})

---@alias RevRange { first: Rev, last: Rev }

---@class Rev : Object
---@field type integer
---@field commit string A commit SHA.
---@field head boolean If true, indicates that the rev should be updated when HEAD changes.
local Rev = oop.create_class("Rev")

-- The special SHA for git's empty tree.
Rev.NULL_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---Rev constructor
---@param type RevType
---@param commit string
---@param head boolean
---@return Rev
function Rev:init(type, commit, head)
  self.type = type
  self.commit = commit
  self.head = head or false
end

---@param name string
---@param git_root? string
---@return Rev
function Rev.from_name(name, git_root)
  local out, code = utils.system_list({ "git", "rev-parse", "--revs-only", name }, git_root)
  if code ~= 0 then
    return
  end

  return Rev(RevType.COMMIT, out[1]:gsub("^%^", ""))
end

---@param git_root string
---@return Rev
function Rev.earliest_commit(git_root)
  local out, code = utils.system_list({
    "git", "rev-list", "--max-parents=0", "--first-parent", "HEAD"
  }, git_root)

  if code ~= 0 then
    return
  end

  return Rev(RevType.COMMIT, ({ out[1]:gsub("^%^", "") })[1])
end

---Get an abbreviated commit SHA. Returns `nil` if this Rev is not a commit.
---@param length integer|nil
---@return string|nil
function Rev:abbrev(length)
  if self.commit then
    return self.commit:sub(1, length or 7)
  end
  return nil
end

---Create a new commit rev with the special empty tree SHA.
---@return Rev
function Rev.new_null_tree()
  return Rev(RevType.COMMIT, Rev.NULL_TREE_SHA)
end

M.RevType = RevType
M.Rev = Rev

return M
