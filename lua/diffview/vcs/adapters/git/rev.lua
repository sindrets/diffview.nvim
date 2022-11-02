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

---@param adapter VCSAdapter
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

function GitRev:object_name()
  if self.type == RevType.COMMIT then
    return self.commit
  elseif self.type == RevType.STAGE then
    return ":" ..  self.stage
  end
end

---Determine if this rev is currently the head.
---@param adapter GitAdapter
---@return boolean?
function Rev:is_head(adapter)
  if not self.type == RevType.COMMIT then
    return false
  end

  local out, code = adapter:exec_sync({ "rev-parse", "HEAD", "--" }, adapter.ctx.toplevel)

  if code ~= 0 or not (out[2] ~= nil or out[1] and out[1] ~= "") then
    return
  end

  return self.commit == vim.trim(out[1]):gsub("^%^", "")
end

---Create a new commit rev with the special empty tree SHA.
---@return Rev
function GitRev.new_null_tree()
  return GitRev(RevType.COMMIT, GitRev.NULL_TREE_SHA)
end

M.GitRev = GitRev
return M
