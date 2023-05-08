local oop = require("diffview.oop")
local Rev = require('diffview.vcs.rev').Rev
local RevType = require('diffview.vcs.rev').RevType

local M = {}

---@class HgRev : Rev
local HgRev = oop.create_class("HgRev", Rev)

HgRev.NULL_TREE_SHA = "0000000000000000000000000000000000000000"

function HgRev:init(rev_type, revision, track_head)
  local t = type(revision)

  assert(
    revision == nil or t == "string" or t == "number",
    "'revision' must be one of: nil, string, number!"
  )
  if t == "string" then
    assert(revision ~= "", "'revision' cannot be an empty string!")
  end

  t = type(track_head)
  assert(t == "boolean" or t == "nil", "'track_head' must be of type boolean!")

  self.type = rev_type
  self.track_head = track_head or false

  self.commit = revision
end

function HgRev.new_null_tree()
  return HgRev(RevType.COMMIT, HgRev.NULL_TREE_SHA)
end

function HgRev:object_name(abbrev_len)
  if self.commit then
    if abbrev_len then
      return self.commit:sub(1, abbrev_len)
    end

    return self.commit
  end

  return "UNKNOWN"
end

---@param rev_from HgRev|string
---@param rev_to HgRev|string
---@return string?
function HgRev.to_range(rev_from, rev_to)
  local name_from = type(rev_from) == "string" and rev_from or rev_from:object_name()
  local name_to

  if rev_to then
    if type(rev_to) == "string" then
      name_to = rev_to
    elseif rev_to.type == RevType.COMMIT then
      name_to = rev_to:object_name()
    end
  end

  if name_from and name_to then
    return name_from .. "::" .. name_to
  else
    return name_from .. "::" .. name_from
  end
end

M.HgRev = HgRev
return M
