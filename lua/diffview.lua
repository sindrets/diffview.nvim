local arg_parser = require'diffview.arg-parser'
local lib = require'diffview.lib'
local config = require'diffview.config'
local colors = require'diffview.colors'
local utils = require "diffview.utils"
local M = {}

local flag_value_completion = arg_parser.FlagValueMap:new()
flag_value_completion:put({"u", "untracked-files"}, {"true", "normal", "all", "false", "no"})

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  colors.setup()
end

function M.open(...)
  local view = lib.parse_revs(utils.tbl_pack(...))
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

  local view = lib.get_current_diffview()
  if view then
    view:close()
    lib.dispose_view(view)
  end
end

function M.completion(arg_lead, cmd_line, cur_pos)
  print(vim.inspect(arg_lead), vim.inspect(cmd_line), cur_pos)
  local args, argidx, divideridx = arg_parser.scan_ex_args(cmd_line, cur_pos)

  print(vim.inspect(args), argidx, divideridx)

  if argidx >= divideridx then
    return vim.fn.getcompletion(arg_lead, "file", 0)
  elseif argidx == 2 then
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

function M.on_tab_enter()
  local view = lib.get_current_diffview()
  if view then
    view:on_enter()
  end
end

function M.on_tab_leave()
  local view = lib.get_current_diffview()
  if view then
    view:on_leave()
  end
end

function M.on_buf_write_post()
  for _, view in ipairs(lib.views) do
    view:on_buf_write_post()
  end
end

function M.on_win_leave()
  local view = lib.get_current_diffview()
  if view then
    view:on_win_leave()
  end
end

function M.update_colors()
  colors.setup()
  lib.update_colors()
end

function M.on_keypress(event_name)
  if M.keypress_event_cbs[event_name] then
    M.keypress_event_cbs[event_name]()
  end
end

M.keypress_event_cbs = {
  select_next_entry = function ()
    local view = lib.get_current_diffview()
    if view then view:next_file() end
  end,
  select_prev_entry = function ()
    local view = lib.get_current_diffview()
    if view then view:prev_file() end
  end,
  next_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      view.file_panel:highlight_next_file()
    end
  end,
  prev_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      view.file_panel:highlight_prev_file()
    end
  end,
  select_entry = function ()
    local view = lib.get_current_diffview()
    if view and view.file_panel:is_open() then
      local file = view.file_panel:get_file_at_cursor()
      if file then view:set_file(file, true) end
    end
  end,
  focus_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view.file_panel:focus(true)
    end
  end,
  toggle_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view.file_panel:toggle()
    end
  end,
  refresh_files = function ()
    local view = lib.get_current_diffview()
    if view then
      view:update_files()
    end
  end
}

M.init()

return M
