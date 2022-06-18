local Event = require("diffview.events").Event
local FileEntry = require("diffview.views.file_entry").FileEntry
local RevType = require("diffview.git.rev").RevType
local api = vim.api
local async = require("plenary.async")
local git = require("diffview.git.utils")
local utils = require("diffview.utils")

---@param view DiffView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_file
      if file then
        view:set_file(file, false, true)
        file:attach_buffers()
      end

      if view.ready then
        view:update_files()
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
    ---@diagnostic disable-next-line: unused-local
    files_updated = function(files)
      view.initialized = true
    end,
    close = function()
      if view.panel:is_focused() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        view:close()
      end
    end,
    select_next_entry = function()
      view:next_file(true)
    end,
    select_prev_entry = function()
      view:prev_file(true)
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
    open_commit_log = function()
      if (view.left.type == RevType.INDEX and view.right.type == RevType.LOCAL)
        or (
          view.left.type == RevType.COMMIT
          and vim.tbl_contains({ RevType.INDEX, RevType.LOCAL }, view.right.type)
          and view.left:is_head(view.git_root)
        ) then
        utils.info("Changes not commited yet. No log available for these changes.")
        return
      end

      local rev_arg = ("%s..%s"):format(view.left.commit, view.right.commit or "HEAD")
      view.commit_log_panel:update(rev_arg)
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.INDEX and view.right.type == RevType.LOCAL) then
        return
      end

      local item = view:infer_cur_file(true)
      if item then
        local code
        if item.kind == "working" then
          _, code = git.exec_sync({ "add", item.path }, view.git_root)
        elseif item.kind == "staged" then
          _, code = git.exec_sync({ "reset", "--", item.path }, view.git_root)
        end

        if code ~= 0 then
          utils.err(("Failed to stage/unstage file: '%s'"):format(item.path))
          return
        end

        if type(item.collapsed) == "boolean" then
          ---@cast item DirData
          ---@type FileTree
          local tree = item.kind == "working"
            and view.panel.files.working_tree
            or view.panel.files.staged_tree

          ---@type Node
          local item_node
          tree.root:deep_some(function (node, _, _)
            if node == item._node then
              item_node = node
              return true
            end
          end)

          if item_node then
            local next_leaf = item_node:next_leaf()
            if next_leaf then
              view:set_file(next_leaf.data)
            else
              view:set_file(view.panel.files[1])
            end
          end
        else
          view.panel:set_cur_file(item)
          view:next_file()
        end

        view:update_files(function()
          view.panel:highlight_cur_file()
        end)
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    stage_all = function()
      local args = vim.tbl_map(function(file)
        return file.path
      end, view.files.working)

      if #args > 0 then
        local _, code = git.exec_sync({ "add", args }, view.git_root)

        if code ~= 0 then
          utils.err("Failed to stage files!")
          return
        end

        view:update_files()
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      local _, code = git.exec_sync({ "reset" }, view.git_root)

      if code ~= 0 then
        utils.err("Failed to unstage files!")
        return
      end

      view:update_files()
      view.emitter:emit(Event.FILES_STAGED, view)
    end,
    restore_entry = async.void(function()
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
        git.restore_file(view.git_root, file.path, file.kind, commit, function()
          async.util.scheduler()
          view:update_files()
        end)
      end
    end),
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
      view.panel:focus()
    end,
    toggle_files = function()
      view.panel:toggle(true)
    end,
    refresh_files = function()
      view:update_files()
    end,
  }
end
