local utils = require("diffview.utils")
local git = require("diffview.git.utils")
local lib = require("diffview.lib")
local RevType = require("diffview.git.rev").RevType
local Event = require("diffview.events").Event
local FileEntry = require("diffview.views.file_entry").FileEntry
local api = vim.api

local function prepare_goto_file(view)
  local file = view:infer_cur_file()
  if file then
    if not file.right.type == RevType.LOCAL then
      -- Ensure file exists
      if vim.fn.filereadable(file.absolute_path) ~= 1 then
        utils.err(
          string.format(
            "File does not exist on disk: '%s'",
            vim.fn.fnamemodify(file.absolute_path, ":.")
          )
        )
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

      local file = view.panel.cur_file
      if file then
        file:attach_buffers()
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_file
      if file then
        file:detach_buffers()
      end
      local cur_winid = api.nvim_get_current_win()
      if cur_winid == view.left_winid or cur_winid == view.right_winid then
        -- Change the current buffer such that 'restore_winopts()' will work
        -- correctly.
        FileEntry.load_null_buffer(cur_winid)
      end
      for _, f in view.panel.files:ipairs() do
        f:restore_winopts()
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
    close = function()
      if view.panel:is_cur_win() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        view:close()
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
        ---@type any
        local item = view.panel:get_item_at_cursor()
        if type(item.collapsed) == "boolean" then
          view.panel:toggle_item_fold(item)
        else
          view:set_file(item, false)
        end
      end
    end,
    focus_entry = function()
      if view.panel:is_open() then
        ---@type any
        local item = view.panel:get_item_at_cursor()
        if type(item.collapsed) == "boolean" then
          view.panel:toggle_item_fold(item)
        else
          view:set_file(item, true)
        end
      end
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.INDEX and view.right.type == RevType.LOCAL) then
        return
      end

      local item = view:infer_cur_file(true)
      if item then
        local code
        if item.kind == "working" then
          _, code = utils.system_list({ "git", "add", item.path }, view.git_root)
        elseif item.kind == "staged" then
          _, code = utils.system_list({ "git", "reset", "--", item.path }, view.git_root)
        end

        if code ~= 0 then
          utils.err(("Failed to stage/unstage file: '%s'"):format(item.path))
          return
        end

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    stage_all = function()
      local args = vim.tbl_map(function(file)
        return file.path
      end, view.files.working)

      if #args > 0 then
        local _, code = utils.system_list(utils.vec_join("git", "add", args), view.git_root)

        if code ~= 0 then
          utils.err("Failed to stage files!")
          return
        end

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      local _, code = utils.system_list({ "git", "reset" }, view.git_root)

      if code ~= 0 then
        utils.err("Failed to unstage files!")
        return
      end

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
    listing_style = function()
      if view.panel.listing_style == "list" then
        view.panel.listing_style = "tree"
      else
        view.panel.listing_style = "list"
      end
      view.panel:update_components()
      view.panel:render()
      view.panel:redraw()
    end,
    toggle_flatten_dirs = function()
      view.panel.tree_options.flatten_dirs = not view.panel.tree_options.flatten_dirs
      view.panel:update_components()
      view.panel:render()
      view.panel:redraw()
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
