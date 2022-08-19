local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

---@module "diffview.git.utils"
local git = lazy.require("diffview.git.utils")

local M = {}

---@class RevType : EnumValue

---@class ERevType
---@field LOCAL RevType
---@field COMMIT RevType
---@field STAGE RevType
---@field CUSTOM RevType
local RevType = oop.enum({
  "LOCAL",
  "COMMIT",
  "STAGE",
  "CUSTOM",
})

---@alias RevRange { first: Rev, last: Rev }

---@class Rev : diffview.Object
---@field type integer
---@field commit? string A commit SHA.
---@field stage? integer A stage number.
---@field track_head boolean If true, indicates that the rev should be updated when HEAD changes.
local Rev = oop.create_class("Rev")

-- The special SHA for git's empty tree.
Rev.NULL_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---Rev constructor
---@param rev_type RevType
---@param revision string|number Commit SHA or stage number.
---@param track_head? boolean
function Rev:init(rev_type, revision, track_head)
  local t = type(revision)

  assert(
    revision == nil or t == "string" or t == "number",
    "'revision' must be one of: nil, string, number!"
  )
  if t == "string" then
    assert(revision ~= "", "'revision' cannot be an empty string!")
  elseif t == "number" then
    assert(
      revision >= 0 and revision <= 3,
      "'revision' must be a valid stage number ([0-3])!"
    )
  end

  t = type(track_head)
  assert(t == "boolean" or t == "nil", "'track_head' must be of type boolean!")

  self.type = rev_type
  self.track_head = track_head or false

  if type(revision) == "string" then
    ---@cast revision string
    self.commit = revision
  elseif type(revision) == "number" then
    ---@cast revision number
    self.stage = revision
  end
end

function Rev:__tostring()
  if self.type == RevType.COMMIT or self.type == RevType.STAGE then
    return self:object_name()
  elseif self.type == RevType.LOCAL then
    return "LOCAL"
  elseif self.type == RevType.CUSTOM then
    return "CUSTOM"
  end
end

---@param name string
---@param git_toplevel? string
---@return Rev?
function Rev.from_name(name, git_toplevel)
  local out, code = git.exec_sync({ "rev-parse", "--revs-only", name }, git_toplevel)

  if code ~= 0 then
    return
  end

  return Rev(RevType.COMMIT, out[1]:gsub("^%^", ""))
end

---@param git_toplevel string
---@return Rev?
function Rev.earliest_commit(git_toplevel)
  local out, code = git.exec_sync({
    "rev-list", "--max-parents=0", "--first-parent", "HEAD"
  }, git_toplevel)

  if code ~= 0 then
    return
  end

  return Rev(RevType.COMMIT, ({ out[1]:gsub("^%^", "") })[1])
end

function Rev:object_name()
  if self.type == RevType.COMMIT then
    return self.commit
  elseif self.type == RevType.STAGE then
    return ":" ..  self.stage
  end
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

---Determine if this rev is currently the head.
---@param git_toplevel string
---@return boolean?
function Rev:is_head(git_toplevel)
  if not self.type == RevType.COMMIT then
    return false
  end

  local out, code = git.exec_sync({ "rev-parse", "HEAD", "--" }, git_toplevel)

  if code ~= 0 or not (out[2] ~= nil or out[1] and out[1] ~= "") then
    return
  end

  return self.commit == vim.trim(out[1]):gsub("^%^", "")
end

---Create a new commit rev with the special empty tree SHA.
---@return Rev
function Rev.new_null_tree()
  return Rev(RevType.COMMIT, Rev.NULL_TREE_SHA)
end

M.RevType = RevType
M.Rev = Rev

return M
