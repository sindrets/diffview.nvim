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

function HgRev:new_null_tree()
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

function HgRev.to_range(rev_from, rev_to)
  if rev_from and rev_to then
    return rev_from.commit .. "::" .. rev_to.commit
  elseif rev_to then
    return "::" .. rev_to.commit
  end
  return rev_from.commit .. "::"
end

M.HgRev = HgRev
return M
