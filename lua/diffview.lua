local arg_parser = require("diffview.arg_parser")
local lib = require("diffview.lib")
local config = require("diffview.config")
local colors = require("diffview.colors")
local utils = require("diffview.utils")
local M = {}

---@type FlagValueMap
local flag_value_completion = arg_parser.FlagValueMap()
flag_value_completion:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
flag_value_completion:put({ "cached", "staged" }, { "true", "false" })
flag_value_completion:put({ "C" }, {})

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  colors.setup()
end

function M.open(...)
  local view = lib.diffview_open(utils.tbl_pack(...))
  if view then
    view:open()
  end
end

function M.file_history(...)
  local view = lib.file_history(utils.tbl_pack(...))
  if view then
    view:open()
  end
end

function M.close(tabpage)
  if tabpage then
    vim.schedule(function()
      lib.dispose_stray_views()
    end)
    return
  end

  local view = lib.get_current_view()
  if view then
    view:close()
    lib.dispose_view(view)
  end
end

local function filter_completion(arg_lead, items)
  return vim.tbl_filter(function(item)
    return item:match(utils.pattern_esc(arg_lead))
  end, items)
end

function M.completion(arg_lead, cmd_line, cur_pos)
  local args, argidx, divideridx = arg_parser.scan_ex_args(cmd_line, cur_pos)
  local fpath = (
      vim.bo.buftype == ""
        and vim.fn.filereadable(vim.fn.expand("%"))
        and vim.fn.expand("%:p:h")
      or "."
    )
  local git_dir = require("diffview.git").git_dir(fpath)
  local git_root = require("diffview.git").toplevel(fpath)

  if argidx >= divideridx then
    return vim.fn.getcompletion(arg_lead, "file", 0)
  elseif argidx == 2 and arg_lead:sub(1, 1) ~= "-" and git_dir and git_root then
    -- stylua: ignore start
    local targets = {
      "HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
      "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"
    }
    local heads = vim.tbl_filter(
      function(name) return vim.tbl_contains(targets, name) end,
      vim.tbl_map(
        function(v) return vim.fn.fnamemodify(v, ":t") end,
        vim.fn.glob(git_dir .. "/*", false, true)
      )
    )
    -- stylua: ignore end
    local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " "
    local revs = vim.fn.systemlist(cmd .. "rev-parse --symbolic --branches --tags --remotes")
    local stashes = vim.fn.systemlist(cmd .. "stash list --pretty=format:%gd")

    return filter_completion(arg_lead, utils.tbl_concat(heads, revs, stashes))
  else
    local flag_completion = flag_value_completion:get_completion(arg_lead)
    if flag_completion then
      return filter_completion(arg_lead, flag_completion)
    end

    return filter_completion(arg_lead, flag_value_completion:get_all_names())
  end

  return args
end

function M.update_colors()
  colors.setup()
  lib.update_colors()
end

function M.trigger_event(event_name)
  local view = lib.get_current_view()
  if view then
    view.emitter:emit(event_name)
  end
end

M.init()

return M
