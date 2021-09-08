local utils = require("diffview.utils")
local git = require("diffview.git.utils")
local lib = require("diffview.lib")
local RevType = require("diffview.git.rev").RevType
local Event = require("diffview.events").Event
local api = vim.api

local function prepare_goto_file(view)
  local file = view:infer_cur_file()
  if file then
    if not file.right.type == RevType.LOCAL then
      -- Ensure file exists
      if vim.fn.filereadable(file.absolute_path) ~= 1 then
        utils.err(string.format(
          "File does not exist on disk: '%s'",
          vim.fn.fnamemodify(file.absolute_path, ":.")
        ))
        return
      end
    end
    return file
  end
end

---@param view DiffView
return function(view)
  return {
    tab_enter = function()
      if view.ready then
        view:update_files()
      end

      local file = view:cur_file()
      if file then
        file:attach_buffers()
      end
    end,
    tab_leave = function()
      local file = view:cur_file()
      if file then
        file:detach_buffers()
      end
    end,
    buf_write_post = function()
      if git.has_local(view.left, view.right) then
        view.update_needed = true
        if api.nvim_get_current_tabpage() == view.tabpage then
          view:update_files()
        end
      end
    end,
    select_next_entry = function()
      view:next_file()
    end,
    select_prev_entry = function()
      view:prev_file()
    end,
    next_entry = function()
      view.panel:highlight_next_file()
    end,
    prev_entry = function()
      view.panel:highlight_prev_file()
    end,
    select_entry = function()
      if view.panel:is_open() then
        local file = view.panel:get_file_at_cursor()
        if file then
          view:set_file(file, false)
        end
      end
    end,
    focus_entry = function()
      if view.panel:is_open() then
        local file = view.panel:get_file_at_cursor()
        if file then
          view:set_file(file, true)
        end
      end
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.INDEX and view.right.type == RevType.LOCAL) then
        return
      end
      local file = view:infer_cur_file()
      if file then
        if file.kind == "working" then
          vim.fn.system(
            "git -C "
              .. vim.fn.shellescape(view.git_root)
              .. " add "
              .. vim.fn.shellescape(file.absolute_path)
          )
        elseif file.kind == "staged" then
          vim.fn.system(
            "git -C "
              .. vim.fn.shellescape(view.git_root)
              .. " reset -- "
              .. vim.fn.shellescape(file.absolute_path)
          )
        end

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    stage_all = function()
      local args = ""
      for _, file in ipairs(view.files.working) do
        args = args .. " " .. vim.fn.shellescape(file.absolute_path)
      end
      if #args > 0 then
        vim.fn.system("git -C " .. vim.fn.shellescape(view.git_root) .. " add" .. args)

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      vim.fn.system("git -C " .. vim.fn.shellescape(view.git_root) .. " reset")

      view:update_files()
      view.emitter:emit(Event.FILES_STAGED, view)
    end,
    restore_entry = function()
      local commit
      if not (view.right.type == RevType.LOCAL) then
        utils.err("The right side of the diff is not local! Aborting file restoration.")
        return
      end
      if not (view.left.type == RevType.INDEX) then
        commit = view.left.commit
      end
      local file = view:infer_cur_file()
      if file then
        local bufid = utils.find_file_buffer(file.path)
        if bufid and vim.bo[bufid].modified then
          utils.err("The file is open with unsaved changes! Aborting file restoration.")
          return
        end
        git.restore_file(view.git_root, file.path, file.kind, commit)
        view:update_files()
      end
    end,
    goto_file = function()
      local file = prepare_goto_file(view)
      if file then
        local target_tab = lib.get_prev_non_view_tabpage()
        if target_tab then
          api.nvim_set_current_tabpage(target_tab)
          vim.cmd("sp " .. vim.fn.fnameescape(file.absolute_path))
          vim.cmd("diffoff")
        else
          vim.cmd("tabe " .. vim.fn.fnameescape(file.absolute_path))
          vim.cmd("diffoff")
        end
      end
    end,
    goto_file_split = function()
      local file = prepare_goto_file(view)
      if file then
        vim.cmd("sp " .. vim.fn.fnameescape(file.absolute_path))
        vim.cmd("diffoff")
      end
    end,
    goto_file_tab = function()
      local file = prepare_goto_file(view)
      if file then
        vim.cmd("tabe " .. vim.fn.fnameescape(file.absolute_path))
        vim.cmd("diffoff")
      end
    end,
    focus_files = function()
      view.panel:focus(true)
    end,
    toggle_files = function()
      view.panel:toggle()
    end,
    refresh_files = function()
      view:update_files()
    end,
  }
end
