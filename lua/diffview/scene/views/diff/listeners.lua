local lazy = require("diffview.lazy")

local actions = lazy.require("diffview.actions") ---@module "diffview.actions"
local Event = lazy.access("diffview.events", "Event") ---@type EEvent
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type ERevType
local async = lazy.require("plenary.async") ---@module "plenary.async"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

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

      for _, f in view.panel.files:ipairs() do
        f.layout:restore_winopts()
      end
    end,
    buf_write_post = function()
      if vcs.has_local(view.left, view.right) then
        view.update_needed = true
        if api.nvim_get_current_tabpage() == view.tabpage then
          view:update_files()
        end
      end
    end,
    diff_buf_read = function(_)
      utils.set_cursor(0, 1, 0)

      if view.cur_layout:get_main_win().id == api.nvim_get_current_win() then
        if view.cur_entry and view.cur_entry.kind == "conflicting" then
          actions.next_conflict()
          vim.cmd("norm! zz")
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
      if (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL)
        or (
          view.left.type == RevType.COMMIT
          and vim.tbl_contains({ RevType.STAGE, RevType.LOCAL }, view.right.type)
          and view.left:is_head(view.adapter.ctx.toplevel)
        ) then
        utils.info("Changes not commited yet. No log available for these changes.")
        return
      end

      local rev_arg = ("%s..%s"):format(view.left.commit, view.right.commit or "HEAD")
      view.commit_log_panel:update(rev_arg)
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL) then
        return
      end

      local item = view:infer_cur_file(true)
      if item then
        local code
        if item.kind == "working" or item.kind == "conflicting" then
          _, code = vcs.exec_sync({ "add", item.path }, view.adapter.ctx.toplevel)
        elseif item.kind == "staged" then
          _, code = vcs.exec_sync({ "reset", "--", item.path }, view.adapter.ctx.toplevel)
        end

        if code ~= 0 then
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
        local _, code = vcs.exec_sync({ "add", args }, view.adapter.ctx.toplevel)

        if code ~= 0 then
          utils.err("Failed to stage files!")
          return
        end

        view:update_files(function()
          view.panel:highlight_cur_file()
        end)
        view.emitter:emit(Event.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      local _, code = vcs.exec_sync({ "reset" }, view.adapter.ctx.toplevel)

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
      if not (view.left.type == RevType.STAGE) then
        commit = view.left.commit
      end
      local file = view:infer_cur_file()
      if file then
        local bufid = utils.find_file_buffer(file.path)
        if bufid and vim.bo[bufid].modified then
          utils.err("The file is open with unsaved changes! Aborting file restoration.")
          return
        end
        vcs.restore_file(view.adapter.ctx.toplevel, file.path, file.kind, commit, function()
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
