local utils = require('diffview.utils')
local git = require('diffview.vcs.adapters.git')
local hg = require('diffview.vcs.adapters.hg')

local M = {}

-- Try to extract paths from arguments to determine VCS type
function M.get_adapter(args)
  local ok = false
  local paths

  paths = git.get_repo_paths(args)
  if paths then
    print('toplevel: ', vim.inspect(paths))
    return git.GitAdapter(paths), paths
  end

  paths = hg.get_repo_paths(args)
  if paths then
    return hg.HgAdapter(paths), paths
  end

  utils.err("No valid VCS found for current workspace")
end

return M
