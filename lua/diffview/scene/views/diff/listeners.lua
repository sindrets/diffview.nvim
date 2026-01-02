local async = require("diffview.async")
local lazy = require("diffview.lazy")

local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local actions = lazy.require("diffview.actions") ---@module "diffview.actions"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api
local await = async.await

---@param view DiffView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_file
      if file then
        view:set_file(file, false, true)
      end

      if view.ready then
        view:update_files()
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_file

      if file then
        file.layout:detach_files()
      end

      for _, f in view.panel.files:iter() do
        f.layout:restore_winopts()
      end
    end,
    buf_write_post = function()
      if view.adapter:has_local(view.left, view.right) then
        view.update_needed = true
        if api.nvim_get_current_tabpage() == view.tabpage then
          view:update_files()
        end
      end
    end,
    file_open_new = function(_, entry)
      api.nvim_win_call(view.cur_layout:get_main_win().id, function()
        utils.set_cursor(0, 1, 0)

        if view.cur_entry and view.cur_entry.kind == "conflicting" then
          actions.next_conflict()
          vim.cmd("norm! zz")
        end
      end)

      view.cur_layout:sync_scroll()
    end,
    ---@diagnostic disable-next-line: unused-local
    files_updated = function(_, files)
      view.initialized = true
    end,
    close = function()
      if view.panel:is_focused() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        view:close()
      end
    end,
    select_first_entry = function()
      local files = view.panel:ordered_file_list()
      if files and #files > 0 then
        view:set_file(files[1], false, true)
      end
    end,
    select_last_entry = function()
      local files = view.panel:ordered_file_list()
      if files and #files > 0 then
        view:set_file(files[#files], false, true)
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
        if item then
          if type(item.collapsed) == "boolean" then
            view.panel:toggle_item_fold(item)
          else
            view:set_file(item, false)
          end
        end
      end
    end,
    focus_entry = function()
      if view.panel:is_open() then
        ---@type any
        local item = view.panel:get_item_at_cursor()
        if item then
          if type(item.collapsed) == "boolean" then
            view.panel:toggle_item_fold(item)
          else
            view:set_file(item, true)
          end
        end
      end
    end,
    open_commit_log = function()
      if view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL then
        utils.info("Changes not committed yet. No log available for these changes.")
        return
      end

      local range = view.adapter.Rev.to_range(view.left, view.right)

      if range then
        view.commit_log_panel:update(range)
      end
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL) then
        return
      end

      local item = view:infer_cur_file(true)
      if item then
        local success
        if item.kind == "working" or item.kind == "conflicting" then
          success = view.adapter:add_files({ item.path })
        elseif item.kind == "staged" then
          success = view.adapter:reset_files({ item.path })
        end

        if not success then
          utils.err(("Failed to stage/unstage file: '%s'"):format(item.path))
          return
        end

        if type(item.collapsed) == "boolean" then
          ---@cast item DirData
          ---@type FileTree
          local tree

          if item.kind == "conflicting" then
            tree = view.panel.files.conflicting_tree
          elseif item.kind == "working" then
            tree = view.panel.files.working_tree
          else
            tree = view.panel.files.staged_tree
          end

          ---@type Node
          local item_node
          tree.root:deep_some(function(node, _, _)
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

        view:update_files(
          vim.schedule_wrap(function()
            view.panel:highlight_cur_file()
          end)
        )
        view.emitter:emit(EventName.FILES_STAGED, view)
      end
    end,
    stage_all = function()
      local args = vim.tbl_map(function(file)
        return file.path
      end, utils.vec_join(view.files.working, view.files.conflicting))

      if #args > 0 then
        local success = view.adapter:add_files(args)

        if not success then
          utils.err("Failed to stage files!")
          return
        end

        view:update_files(function()
          view.panel:highlight_cur_file()
        end)
        view.emitter:emit(EventName.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      local success = view.adapter:reset_files()

      if not success then
        utils.err("Failed to unstage files!")
        return
      end

      view:update_files()
      view.emitter:emit(EventName.FILES_STAGED, view)
    end,
    restore_entry = async.void(function()
      if view.right.type ~= RevType.LOCAL then
        utils.err("The right side of the diff is not local! Aborting file restoration.")
        return
      end

      local commit

      if view.left.type ~= RevType.STAGE then
        commit = view.left.commit
      end

      local file = view:infer_cur_file()
      if not file then return end

      local bufid = utils.find_file_buffer(file.path)

      if bufid and vim.bo[bufid].modified then
        utils.err("The file is open with unsaved changes! Aborting file restoration.")
        return
      end

      await(vcs_utils.restore_file(view.adapter, file.path, file.kind, commit))
      view:update_files()
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
    open_all_folds = function()
      if not view.panel:is_focused() or view.panel.listing_style ~= "tree" then return end

      for _, file_set in ipairs({
        view.panel.components.conflicting.files,
        view.panel.components.working.files,
        view.panel.components.staged.files,
      }) do
        file_set.comp:deep_some(function(comp, _, _)
          if comp.name == "directory" then
            (comp.context --[[@as DirData ]]).collapsed = false
          end
        end)
      end

      view.panel:render()
      view.panel:redraw()
    end,
    close_all_folds = function()
      if not view.panel:is_focused() or view.panel.listing_style ~= "tree" then return end

      for _, file_set in ipairs({
        view.panel.components.conflicting.files,
        view.panel.components.working.files,
        view.panel.components.staged.files,
      }) do
        file_set.comp:deep_some(function(comp, _, _)
          if comp.name == "directory" then
            (comp.context --[[@as DirData ]]).collapsed = true
          end
        end)
      end

      view.panel:render()
      view.panel:redraw()
    end,
    open_fold = function()
      if not view.panel:is_focused() then return end
      local dir = view.panel:get_dir_at_cursor()
      if dir then view.panel:set_item_fold(dir, true) end
    end,
    close_fold = function()
      if not view.panel:is_focused() then return end
      local dir, comp = view.panel:get_dir_at_cursor()
      if dir and comp then
        if not dir.collapsed then
          view.panel:set_item_fold(dir, false)
        else
          local dir_parent = utils.tbl_access(comp, "parent.parent")
          if dir_parent and dir_parent.name == "directory" then
            view.panel:set_item_fold(dir_parent.context, false)
          end
        end
      end
    end,
    toggle_fold = function()
      if not view.panel:is_focused() then return end
      local dir = view.panel:get_dir_at_cursor()
      if dir then view.panel:toggle_item_fold(dir) end
    end,
  }
end
