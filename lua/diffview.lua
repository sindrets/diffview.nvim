local arg_parser = require'diffview.arg_parser'
local lib = require'diffview.lib'
local Event = require'diffview.events'.Event
local RevType = require'diffview.rev'.RevType
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

  local view = lib.get_current_diffview()
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
  local view = lib.get_current_diffview()
  if view then
    view:trigger_enter()
  end
end

function M.trigger_tab_leave()
  local view = lib.get_current_diffview()
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
  local view = lib.get_current_diffview()
  if view then
    view:trigger_win_leave()
  end
end

function M.update_colors()
  colors.setup()
  lib.update_colors()
end

function M.trigger_event(event_name)
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
  toggle_stage_entry = function ()
    local view = lib.get_current_diffview()
    if view then
      if not (view.left.type == RevType.INDEX and view.right.type == RevType.LOCAL) then
        return
      end
      local file = lib.infer_cur_file(view)
      if file then
        if file.kind == "working" then
          vim.fn.system(
            "git -C " .. vim.fn.shellescape(view.git_root)
            .. " add " .. vim.fn.shellescape(file.absolute_path)
          )
        elseif file.kind == "staged" then
          vim.fn.system(
            "git -C " .. vim.fn.shellescape(view.git_root)
            .. " reset " .. vim.fn.shellescape(file.absolute_path)
          )
        end

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, { view })
      end
    end
  end,
  stage_all = function ()
    local view = lib.get_current_diffview()
    if view then
      local args = ""
      for _, file in ipairs(view.files.working) do
        args = args .. " " .. vim.fn.shellescape(file.absolute_path)
      end
      if #args > 0 then
        vim.fn.system(
          "git -C " .. vim.fn.shellescape(view.git_root)
          .. " add" .. args
        )

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, { view })
      end
    end
  end,
  unstage_all = function ()
    local view = lib.get_current_diffview()
    if view then
      vim.fn.system("git -C " .. vim.fn.shellescape(view.git_root) .. " reset")

      view:update_files()
      view.emitter:emit(Event.FILES_STAGED, { view })
    end
  end,
  restore_entry = function ()
    local view = lib.get_current_diffview()
    if view then
      local commit
      if not (view.right.type == RevType.LOCAL) then
        utils.err("The right side of the diff is not local! Aborting file restoration.")
        return
      end
      if not (view.left.type == RevType.INDEX) then
        commit = view.left.commit
      end
      local file = lib.infer_cur_file(view)
      if file then
        local bufid = utils.find_file_buffer(file.path)
        if bufid and vim.bo[bufid].modified then
          utils.err("The file is open with unsaved changes! Aborting file restoration.")
          return
        end
        require'diffview.git'.restore_file(view.git_root, file.path, file.kind, commit)
        view:update_files()
      end
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
