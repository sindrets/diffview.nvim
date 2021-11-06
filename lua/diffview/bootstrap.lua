if DiffviewGlobal and DiffviewGlobal.bootstrap_done then
  return DiffviewGlobal.bootstrap_ok
end

local function err(msg)
  msg = msg:gsub("'", "''")
  vim.cmd("echohl Error")
  vim.cmd(string.format("echom '%s'", msg))
  vim.cmd("echohl NONE")
end

_G.DiffviewGlobal = {
  bootstrap_done = true,
  bootstrap_ok = false,
}

-- Ensure dependencies
local ok = pcall(require, "plenary")
if not ok then
  err(
    "[diffview.nvim] Dependency 'plenary.nvim' is not installed! "
    .. "See ':h diffview.changelog-93' for more information."
  )
  return false
end

_G.DiffviewGlobal = {
  ---Debug Levels:
  ---0:    NOTHING
  ---1:    NORMAL
  ---10:   RENDERING
  debug_level = tonumber(os.getenv("DEBUG_DIFFVIEW")) or 0,
  bootstrap_done = true,
  bootstrap_ok = true,
}

return true
