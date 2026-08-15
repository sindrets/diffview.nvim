--[[
Display options for the diff windows: the equivalents of VSCode's "Ignore Trim
Whitespace" and "Show / Hide Unchanged Regions" toggles.

This is also where 'diffopt' is managed. It's a global option, so the value the
user had is saved while any view is open, and restored once the last one is
closed.
--]]

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

local M = {}

-- All the 'diffopt' flags that this module manages. Anything else the user has
-- configured is left alone.
local MANAGED_FLAGS = {
  "iwhite", "iwhiteall", "iwhiteeol", "iblank",
  "algorithm:", "linematch:", "internal",
}

---The state of 'diffopt' from before the first view took over, and the number
---of views that are currently relying on it.
local global = { saved = nil, refs = 0 }

---@class diffview.DiffOptions
---@field ignore_whitespace boolean
---@field unchanged_hidden boolean
---@field entered boolean

---@param view StandardView
---@return diffview.DiffOptions
function M.get(view)
  if not view.diff_options then
    view.diff_options = {
      ignore_whitespace = false,
      -- Diff windows start out with 'foldlevel' set to 0: unchanged regions
      -- are hidden by default.
      unchanged_hidden = true,
      entered = false,
    }
  end

  return view.diff_options
end

---@param flag string
---@return boolean
local function is_managed(flag)
  for _, managed in ipairs(MANAGED_FLAGS) do
    if flag == managed or (managed:sub(-1) == ":" and vim.startswith(flag, managed)) then
      return true
    end
  end

  return false
end

---Rebuild 'diffopt' from the user's value, the configured diff algorithm, and
---the display options of the given view.
---@param view StandardView
local function apply_diffopt(view)
  if not global.saved then return end

  local opts = M.get(view)
  local conf = config.get_config().diffopt or {}

  local flags = vim.tbl_filter(function(flag)
    return not is_managed(flag)
  end, vim.split(global.saved, ",", { trimempty = true })) --[[@as string[] ]]

  local function add(flag) flags[#flags + 1] = flag end

  if conf.algorithm or conf.linematch then
    -- Both of these require the internal diff library.
    add("internal")
  end

  if conf.algorithm then add("algorithm:" .. conf.algorithm) end

  -- 'linematch' lines up the individual lines of a change block, which is what
  -- makes the within-line highlighting useful.
  if conf.linematch and vim.fn.has("nvim-0.9") == 1 then
    add("linematch:" .. conf.linematch)
  end

  if opts.ignore_whitespace then
    add("iwhiteall")
    add("iblank")
  end

  vim.o.diffopt = table.concat(flags, ",")
end

---@param view StandardView
local function refresh_diffs(view)
  if not (view.cur_layout and view.cur_layout:is_valid()) then return end

  for _, win in ipairs(view.cur_layout.windows) do
    if api.nvim_win_is_valid(win.id) then
      local done = api.nvim_win_call(win.id, function()
        if not vim.wo.diff then return false end
        vim.cmd("diffupdate")
        return true
      end)

      if done then return end
    end
  end
end

---Take over 'diffopt' for the duration of the view. Called when a view opens.
---@param view StandardView
function M.enter(view)
  local opts = M.get(view)

  if opts.entered then return end
  opts.entered = true

  global.refs = global.refs + 1
  if global.refs == 1 then global.saved = vim.o.diffopt end

  apply_diffopt(view)
end

---Give 'diffopt' back once the last view is closed.
---@param view StandardView
function M.restore(view)
  local opts = view.diff_options

  if not (opts and opts.entered) then return end
  opts.entered = false

  global.refs = math.max(global.refs - 1, 0)

  if global.refs == 0 and global.saved then
    vim.o.diffopt = global.saved
    global.saved = nil
  end
end

---Re-apply the current display options to the windows of the current layout.
---@param view StandardView
function M.apply(view)
  local opts = M.get(view)

  if not (view.cur_layout and view.cur_layout:is_valid()) then return end

  for _, win in ipairs(view.cur_layout.windows) do
    if win.file and api.nvim_win_is_valid(win.id) then
      win:use_winopts({
        foldenable = true,
        foldlevel = opts.unchanged_hidden and 0 or 99,
      })
    end
  end
end

---Toggle whether whitespace-only changes are shown in the diff.
---@param view StandardView
function M.toggle_ignore_whitespace(view)
  local opts = M.get(view)

  M.enter(view)
  opts.ignore_whitespace = not opts.ignore_whitespace

  apply_diffopt(view)
  refresh_diffs(view)

  utils.info(("Whitespace changes are now %s."):format(
    opts.ignore_whitespace and "ignored" or "shown"
  ))
end

---Toggle whether the regions that didn't change are folded away.
---@param view StandardView
function M.toggle_unchanged(view)
  local opts = M.get(view)
  opts.unchanged_hidden = not opts.unchanged_hidden

  M.apply(view)

  utils.info(("Unchanged regions are now %s."):format(
    opts.unchanged_hidden and "hidden" or "shown"
  ))
end

return M
