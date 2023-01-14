local oop = require("diffview.oop")
local Rev = require('diffview.vcs.rev').Rev
local RevType = require('diffview.vcs.rev').RevType

local M = {}

---@class GitRev : Rev
local GitRev = oop.create_class("GitRev", Rev)

-- The special SHA for git's empty tree.
GitRev.NULL_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---GitRev constructor
---@param rev_type RevType
---@param revision string|number Commit SHA or stage number.
---@param track_head? boolean
function GitRev:init(rev_type, revision, track_head)
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

  if self.type == RevType.STAGE and not self.stage then
    self.stage = 0
  end
end

---@param rev_from GitRev|string
---@param rev_to? GitRev|string
---@return string?
function GitRev.to_range(rev_from, rev_to)
  if type(rev_from) ~= "string" and rev_from.type ~= RevType.COMMIT then
    -- The range between either LOCAL or STAGE, and any other rev, will always
    -- be empty.
    return nil
  end

  local name_from = type(rev_from) == "string" and rev_from or rev_from:object_name()
  local name_to

  if rev_to then
    if type(rev_to) == "string" then
      name_to = rev_to
    else
      -- If the rev is either of type LOCAL or STAGE, just fall back to HEAD.
      name_to = rev_to.type == RevType.COMMIT and rev_to:object_name() or "HEAD"
    end
  end

  if not name_to then
    return name_from .. "^!"
  else
    return name_from .. ".." .. name_to
  end
end

---@param name string
---@param adapter GitAdapter
---@return Rev?
function GitRev.from_name(name, adapter)
  local out, code = adapter:exec_sync({ "rev-parse", "--revs-only", name }, adapter.ctx.toplevel)

  if code ~= 0 then
    return
  end

  return GitRev(RevType.COMMIT, out[1]:gsub("^%^", ""))
end

---@param adapter GitAdapter
---@return Rev?
function GitRev.earliest_commit(adapter)
  local out, code = adapter:exec_sync({
    "rev-list", "--max-parents=0", "--first-parent", "HEAD"
  }, adapter.ctx.toplevel)

  if code ~= 0 then
    return
  end

  return GitRev(RevType.COMMIT, ({ out[1]:gsub("^%^", "") })[1])
end

---Create a new commit rev with the special empty tree SHA.
---@return Rev
function GitRev.new_null_tree()
  return GitRev(RevType.COMMIT, GitRev.NULL_TREE_SHA)
end

---Determine if this rev is currently the head.
---@param adapter GitAdapter
---@return boolean?
function GitRev:is_head(adapter)
  if self.type ~= RevType.COMMIT then
    return false
  end

  local out, code = adapter:exec_sync({ "rev-parse", "HEAD", "--" }, adapter.ctx.toplevel)

  if code ~= 0 or not (out[2] ~= nil or out[1] and out[1] ~= "") then
    return
  end

  return self.commit == vim.trim(out[1]):gsub("^%^", "")
end

---@param abbrev_len? integer
---@return string
function GitRev:object_name(abbrev_len)
  if self.type == RevType.COMMIT then
    if abbrev_len then
      return self.commit:sub(1, abbrev_len)
    end

    return self.commit
  elseif self.type == RevType.STAGE then
    return ":" ..  self.stage
  end

  return "UNKNOWN"
end

M.GitRev = GitRev
return M
