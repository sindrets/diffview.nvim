local arg_parser = require'diffview.arg_parser'
local lib = require'diffview.lib'
local config = require'diffview.config'
local colors = require'diffview.colors'
local utils = require "diffview.utils"
local M = {}

local flag_value_completion = arg_parser.FlagValueMap()
flag_value_completion:put({"u", "untracked-files"}, {"true", "normal", "all", "false", "no"})
flag_value_completion:put({"cached", "staged"}, {"true", "false"})
flag_value_completion:put({"C"}, {})

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  colors.setup()
end

function M.open(...)
  local view = lib.process_args(utils.tbl_pack(...))
  if view then
    view:open()
  end
end

function M.close(tabpage)
  if tabpage then
    vim.schedule(function ()
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

function M.completion(arg_lead, cmd_line, cur_pos)
  local args, argidx, divideridx = arg_parser.scan_ex_args(cmd_line, cur_pos)

  if argidx >= divideridx then
    return vim.fn.getcompletion(arg_lead, "file", 0)
  elseif argidx == 2 and arg_lead:sub(1, 1) ~= "-" then
    local commits = vim.fn.systemlist("git rev-list --max-count=30 --abbrev-commit HEAD")
    if arg_lead:match(".*%.%..*") then
      arg_lead = arg_lead:gsub("(.*%.%.)(.*)", "%1")
      for k, v in pairs(commits) do
        commits[k] = arg_lead .. v
      end
    end
    return commits
  else
    local flag_completion = flag_value_completion:get_completion(arg_lead)
    if flag_completion then return flag_completion end

    return flag_value_completion:get_all_names()
  end
  return args
end

function M.trigger_tab_enter()
  local view = lib.get_current_view()
  if view then
    view:trigger_enter()
  end
end

function M.trigger_tab_leave()
  local view = lib.get_current_view()
  if view then
    view:trigger_leave()
  end
end

function M.trigger_buf_write_post()
  for _, view in ipairs(lib.views) do
    view:trigger_buf_write_post()
  end
end

function M.trigger_win_leave()
  local view = lib.get_current_view()
  if view then
    view:trigger_win_leave()
  end
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
