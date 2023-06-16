local mock = require("luassert.mock")
local spy = require("luassert.spy")

local M = {}

---@generic T
---@param t T
---@return T
local function tbl_clone(t)
  local ret = {}
  for k, v in pairs(t) do ret[k] = v end
  local mt = getmetatable(t)
  if mt then setmetatable(ret, mt) end

  return ret
end

---@param opt? table
---@param overrides? table
---@return GitAdapter
function M.new_dummy_adapter(opt, overrides)
  opt = opt or {}
  local toplevel = opt.toplevel or "/fake/path"
  local pl = require("diffview.utils").path

  local OrigGitAdapter = require("diffview.vcs.adapters.git").GitAdapter
  local Dummy = tbl_clone(OrigGitAdapter)

  function Dummy:get_dir(path)
    return pl:join(toplevel, ".git")
  end

  return Dummy({
    toplevel = toplevel,
    path_args = opt.path_args,
    cpath = opt.cpath,
  })
end

---@return GitCommit
function M.new_dummy_commit(opt)
  opt = opt or {}
  local Commit = require("diffview.vcs.commit").Commit

  return Commit({
    hash = opt.hash or "0000000000000000000000000000000000000000",
    author = opt.author or "John Smith",
    time = opt.time or 0,
    time_offset = opt.time_offset or "+0000",
    rel_date = opt.rel_date or nil,
    ref_names = opt.ref_names or nil,
    subject = opt.subject or "Example commit",
    diff = opt.diff or nil,
  })
end

return M
