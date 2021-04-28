local lib = require'diffview.lib'
local M = {}

function M.init()

end

function M.open(args)
  print(vim.inspect(args))
  local v = lib.parse_revs(args)
  print(vim.inspect(v))
end

M.init()

return M
