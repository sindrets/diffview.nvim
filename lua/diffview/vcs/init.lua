local git = require('diffview.vcs.adapters.git')
local hg = require('diffview.vcs.adapters.hg')

local M = {}

---@class vcs.init.get_adapter.Opt
---@field top_indicators string[]?
---@field cmd_ctx vcs.init.get_adapter.Opt.Cmd_Ctx? # Context data from a command call.

---@class vcs.init.get_adapter.Opt.Cmd_Ctx
---@field path_args string[] # Raw path args
---@field cpath string? # Cwd path given by the `-C` flag option

---@param opt vcs.init.get_adapter.Opt
---@return string? err
---@return VCSAdapter? adapter
function M.get_adapter(opt)
  local adapters = { git, hg }

  if not opt.cmd_ctx then
    opt.cmd_ctx = {}
  end

  for _, adapter in ipairs(adapters) do
    local path_args
    local top_indicators = opt.top_indicators

    if not top_indicators then
      path_args, top_indicators = adapter.get_repo_paths(opt.cmd_ctx.path_args, opt.cmd_ctx.cpath)
    end
    local err, toplevel = adapter.find_toplevel(top_indicators)

    if not err then
      -- Create a new adapter instance. Store the resolved path args and the
      -- cpath in the adapter context.
      return adapter.create(toplevel, path_args, opt.cmd_ctx.cpath)
    end
  end

  return "Not a repo (or any parent), or no supported VCS adapter!"
end

return M
