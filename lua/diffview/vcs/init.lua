local utils = require('diffview.utils')
local git = require('diffview.vcs.adapters.git')
local hg = require('diffview.vcs.adapters.hg')

local M = {}

-- Try to extract paths from arguments to determine VCS type
function M.get_adapter(args)
  local ok = false
  local paths

  ok, paths = git.get_repo_paths(args)
  if ok then
    return git.GitAdapter(paths)
  end

  ok, paths = hg.get_repo_paths(args)
  if ok then
    return hg.HgAdapter(paths)
  end

  utils.err("No valid VCS found for current workspace")
end

return M
