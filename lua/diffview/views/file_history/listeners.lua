local DiffView = require("diffview.views.diff.diff_view").DiffView
local FileEntry = require("diffview.views.file_entry").FileEntry
local api = vim.api
local git = require("diffview.git.utils")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_item[2]
      if file then
        view:set_file(file)
        file:attach_buffers()
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_item[2]
      if file then
        file:detach_buffers()
      end
      local cur_winid = api.nvim_get_current_win()
      if cur_winid == view.left_winid or cur_winid == view.right_winid then
        -- Change the current buffer such that 'restore_winopts()' will work
        -- correctly.
        FileEntry.load_null_buffer(cur_winid)
      end
      for _, entry in ipairs(view.panel.entries) do
        for _, f in ipairs(entry.files) do
          f:restore_winopts()
        end
      end
    end,
    diff_buf_read = function(bufid)
      -- Set the cursor at the beginning of the -L range if possible.

      local log_options = view.panel:get_log_options()
      local cur = view.panel:cur_file()

      if log_options.L[1] and bufid == cur.right_bufid then
        for _, value in ipairs(log_options.L) do
          local l1, lpath = value:match("^(%d+),.*:(.*)")

          if l1 then
            l1 = tonumber(l1)
            lpath = utils.path:chain(lpath)
                :normalize({ cwd = view.git_root, absolute = true })
                :relative(view.git_root)
                :get()

            print(l1, lpath)
            if lpath == cur.path then
              vim.fn.cursor(l1, 1)
              vim.cmd("norm! zt")
              break
            end
          end
        end
      end
    end,
    open_in_diffview = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          ---@type FileEntry
          local file
          if item.files then
            file = item.files[1]
          else
            file = item
          end

          if file then
            ---@type DiffView
            local new_view = DiffView({
              git_root = view.git_root,
              rev_arg = git.rev_to_pretty_string(file.left, file.right),
              left = file.left,
              right = file.right,
              options = {},
            })

            lib.add_view(new_view)
            new_view:open()
          end
        end
      end
    end,
    select_next_entry = function()
      view:next_item()
    end,
    select_prev_entry = function()
      view:prev_item()
    end,
    next_entry = function()
      view.panel:highlight_next_file()
    end,
    prev_entry = function()
      view.panel:highlight_prev_item()
    end,
    select_entry = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          if item.files then
            if view.panel.single_file then
              view:set_file(item.files[1], false)
            else
              view.panel:toggle_entry_fold(item)
            end
          else
            view:set_file(item, false)
          end
        end
      elseif view.panel.option_panel:is_focused() then
        local item = view.panel.option_panel:get_item_at_cursor()
        if item then
          view.panel.option_panel.emitter:emit("set_option", item[1])
        end
      end
    end,
    focus_entry = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          if item.files then
            if view.panel.single_file then
              view:set_file(item.files[1], true)
            else
              view.panel:toggle_entry_fold(item)
            end
          else
            view:set_file(item, true)
          end
        end
      end
    end,
    open_commit_log = function()
      local file = view:infer_cur_file()
      if file then
        local entry = view.panel:find_entry(file)
        if entry then
          view.commit_log_panel:update(entry.commit.hash .. "^!")
        end
      end
    end,
    focus_files = function()
      view.panel:focus()
    end,
    toggle_files = function()
      view.panel:toggle(true)
    end,
    open_all_folds = function()
      if view.panel:is_focused() and not view.panel.single_file then
        for _, entry in ipairs(view.panel.entries) do
          entry.folded = false
        end
        view.panel:render()
        view.panel:redraw()
      end
    end,
    close_all_folds = function()
      if view.panel:is_focused() and not view.panel.single_file then
        for _, entry in ipairs(view.panel.entries) do
          entry.folded = true
        end
        view.panel:render()
        view.panel:redraw()
      end
    end,
    close = function()
      if view.panel.option_panel:is_focused() then
        view.panel.option_panel:close()
      elseif view.panel:is_focused() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        view:close()
      end
    end,
    options = function()
      view.panel.option_panel:focus()
    end,
    copy_hash = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          vim.fn.setreg("+", item.commit.hash)
          utils.info(string.format("Copied '%s' to the clipboard.", item.commit.hash))
        end
      end
    end,
  }
end
