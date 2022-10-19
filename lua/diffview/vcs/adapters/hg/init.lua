local oop = require('diffview.oop')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

local M = {}

local HgAdapter = oop.create_class('HgAdapter', VCSAdapter)

function M.get_repo_paths(args)
  -- TODO: implement
  return false
end

M.HgAdapter = HgAdapter
return M
