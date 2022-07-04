if DiffviewGlobal and DiffviewGlobal.bootstrap_done then
  return DiffviewGlobal.bootstrap_ok
end

local function err(msg)
  msg = msg:gsub("'", "''")
  vim.cmd("echohl Error")
  vim.cmd(string.format("echom '[diffview.nvim] %s'", msg))
  vim.cmd("echohl NONE")
end

local function exists_in_runtime(module_name)
  --#region From neovim/runtime/lua/vim/_init_packages.lua:
  local basename = module_name:gsub('%.', '/')
  local paths = { "lua/" .. basename .. ".lua", "lua/" .. basename .. "/init.lua" }

  local found = vim.api.nvim__get_runtime(paths, false, { is_lua = true })
  if found[1] then
    return true
  end

  local so_paths = {}
  for _, trail in ipairs(vim._so_trails) do
    local path = "lua" .. trail:gsub('?', basename) -- so_trails contains a leading slash
    table.insert(so_paths, path)
  end

  found = vim.api.nvim__get_runtime(so_paths, false, { is_lua = true })
  if found[1] then
    return true
  end
  --#endregion

  return false
end

local function is_module_available(name)
  if package.loaded[name] then
    return true
  end

  ---@diagnostic disable-next-line: undefined-field
  if _G.__luacache and _G.__luacache.print_profile then
    -- WORKAROUND: If the user has impatient.nvim with profiling enabled: just
    -- do a normal require.
    -- @See [issue #144](https://github.com/sindrets/diffview.nvim/issues/144).
    local ok, _ = pcall(require, name)
    return ok
  end

  return exists_in_runtime(name)
end

_G.DiffviewGlobal = {
  bootstrap_done = true,
  bootstrap_ok = false,
}

if vim.fn.has("nvim-0.7") ~= 1 then
  err(
    "Minimum required version is Neovim 0.7.0! Cannot continue."
    .. " (See ':h diffview.changelog-137')"
  )
  return false
end

-- Ensure dependencies
if not is_module_available("plenary") then
  err(
    "Dependency 'plenary.nvim' is not installed! "
    .. "See ':h diffview.changelog-93' for more information."
  )
  return false
end

_G.DiffviewGlobal = {
  ---Debug Levels:
  ---0:     NOTHING
  ---1:     NORMAL
  ---5:     LOADING
  ---10:    RENDERING
  debug_level = tonumber(os.getenv("DEBUG_DIFFVIEW")) or 0,
  ---@type EventEmitter
  emitter = require("diffview.events").EventEmitter(),
  state = {},
  bootstrap_done = true,
  bootstrap_ok = true,
}

DiffviewGlobal.emitter:on_any(function(event, args)
  local utils = require("diffview.utils")
  require("diffview").nore_emit(event, utils.tbl_unpack(args))
  require("diffview.config").user_emitter:nore_emit(event, utils.tbl_unpack(args))
end)

return true
