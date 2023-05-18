local oop = require("diffview.oop")

local M = {}

---@enum RevType
local RevType = oop.enum({
  LOCAL   = 1,
  COMMIT  = 2,
  STAGE   = 3,
  CUSTOM  = 4,
})

---@alias RevRange { first: Rev, last: Rev }

---@class Rev : diffview.Object
---@field type integer
---@field commit? string A commit SHA.
---@field stage? integer A stage number.
---@field track_head boolean If true, indicates that the rev should be updated when HEAD changes.
local Rev = oop.create_class("Rev")

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

---@diagnostic disable: unused-local, missing-return

---Get the argument describing the range between the two given revs. If a
---single rev is given, the returned argument describes the *range* of the
---single commit pointed to by that rev.
---@abstract
---@param rev_from Rev|string
---@param rev_to? Rev|string
---@return string?
function Rev.to_range(rev_from, rev_to) oop.abstract_stub() end

---@param name string
---@param adapter? VCSAdapter
---@return Rev?
function Rev.from_name(name, adapter)
  oop.abstract_stub()
end

---@param adapter VCSAdapter
---@return Rev?
function Rev.earliest_commit(adapter)
  oop.abstract_stub()
end

---Create a new commit rev with the special empty tree SHA.
---@return Rev
function Rev.new_null_tree()
  oop.abstract_stub()
end

---Determine if this rev is currently the head.
---@param adapter VCSAdapter
---@return boolean?
function Rev:is_head(adapter)
  oop.abstract_stub()
end

---@param abbrev_len? integer
---@return string
function Rev:object_name(abbrev_len)
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---Get an abbreviated commit SHA. Returns `nil` if this Rev is not a commit.
---@param length integer|nil
---@return string|nil
function Rev:abbrev(length)
  if self.commit then
    return self.commit:sub(1, length or 7)
  end
  return nil
end

M.RevType = RevType
M.Rev = Rev

return M
