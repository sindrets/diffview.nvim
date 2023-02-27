local health = vim.health or require("health")

local M = {}

M.plugin_deps = {
  {
    name = "plenary",
    optional = false,
  },
  {
    name = "nvim-web-devicons",
    optional = true,
  },
}

---@param cmd string|string[]
---@return string[] stdout
---@return integer code
local function system_list(cmd)
  local out = vim.fn.systemlist(cmd)
  return out or {}, vim.v.shell_error
end

local function lualib_available(name)
  local ok, _ = pcall(require, name)
  return ok
end

function M.check()
  if vim.fn.has("nvim-0.7") == 0 then
    health.report_error("Diffview.nvim requires Neovim 0.7.0+")
  end

  health.report_start("Checking plugin dependencies")

  local missing_essential = false

  for _, plugin in ipairs(M.plugin_deps) do
    if lualib_available(plugin.name) then
      health.report_ok(plugin.name .. " installed.")
    else
      if plugin.optional then
        health.report_warn(("Optional dependency '%s' not found."):format(plugin.name))
      else
        missing_essential = true
        health.report_error(("Dependency '%s' not found!"):format(plugin.name))
      end
    end
  end

  health.report_start("Checking external dependencies")

  ;(function()
    if missing_essential then
      health.report_warn("Cannot perform checks on external dependencies without all essential plugin dependencies installed!")
      return
    end

    local adapter_kinds = {
      { class = require("diffview.vcs.adapters.git").GitAdapter, name = "Git" },
      { class = require("diffview.vcs.adapters.hg").HgAdapter, name = "Mercurial" },
    }

    for _, kind in ipairs(adapter_kinds) do
      local bs = kind.class.bootstrap
      if not bs.done then kind.class.run_bootstrap() end

      if bs.version_string then
        health.report_ok(("%s found."):format(kind.name))
      end

      if bs.ok then
        health.report_ok(("%s is up-to-date. (%s)"):format(kind.name, bs.version_string))
      else
        health.report_error(bs.err or (kind.name .. ": Unknown error"))
      end
    end
  end)()
end

return M
