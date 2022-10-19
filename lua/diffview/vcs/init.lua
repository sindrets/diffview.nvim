local utils = require('diffview.utils')
local git = require('diffview.vcs.adapters.git')
local hg = require('diffview.vcs.adapters.hg')

local M = {}

-- Try to extract paths from arguments to determine VCS type
function M.get_adapter(args)
  local paths

  paths, toplevel_indicators = git.get_repo_paths(args)
  if paths then
    return git.GitAdapter(toplevel_indicators), paths
  end

  paths, toplevel_indicators = hg.get_repo_paths(args)
  if paths then
    return hg.HgAdapter(toplevel_indicators), paths
  end

  utils.err("No valid VCS found for current workspace")
end

return M
