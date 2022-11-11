local oop = require('diffview.oop')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

local M = {}

local HgAdapter = oop.create_class('HgAdapter', VCSAdapter)

function M.get_repo_paths(args)
  -- TODO: implement
  return nil
end

function M.find_toplevel(top_indicators)
  -- TODO: implement
  return "", nil
end

M.HgAdapter = HgAdapter
return M
