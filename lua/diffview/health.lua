local health = vim.health or require("health")
local config = require("diffview.config")

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

  for _, plugin in ipairs(M.plugin_deps) do
    if lualib_available(plugin.name) then
      health.report_ok(plugin.name .. " installed.")
    else
      if plugin.optional then
        health.report_warn(("Optional dependency '%s' not found."):format(plugin.name))
      else
        health.report_error(("Dependency '%s' not found!"):format(plugin.name))
      end
    end
  end

  health.report_start("Checking external dependencies")

  -- Git
  ;(function()
    local conf = config.get_config()
    local out, code = system_list(vim.tbl_flatten({ conf.git_cmd, "version" }))

    if code ~= 0 or not out[1] then
      health.report_error(
        "Configured git command is not executable: " .. table.concat(conf.git_cmd, " "
      ))
      return
    else
      health.report_ok("Git found.")
    end

    local version_string = out[1]:match("git version (%S+)")

    if not version_string then
      health.report_error("Could not determine git version!")
      return
    end

    local current = {}
    local target = {
      major = 2,
      minor = 31,
      patch = 0,
    }
    local target_version_string = ("%d.%d.%d"):format(target.major, target.minor, target.patch)
    local parts = vim.split(version_string, "%.")
    current.major = tonumber(parts[1])
    current.minor = tonumber(parts[2])
    current.patch = tonumber(parts[3]) or 0

    local cs = ("%08d%08d%08d"):format(current.major, current.minor, current.patch)
    local ts = ("%08d%08d%08d"):format(target.major, target.minor, target.patch)

    if cs < ts then
      health.report_error(("Git version is outdated! Wanted: %s, current: %s"):format(
        target_version_string,
        version_string
      ))
    else
      health.report_ok("Git is up-to-date.")
    end
  end)()
end

return M
