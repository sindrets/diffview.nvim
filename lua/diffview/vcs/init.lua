local git = require('diffview.vcs.adapters.git').GitAdapter

local M = {}

function M.get_adapter(path)
  return git(path)
end

return M
