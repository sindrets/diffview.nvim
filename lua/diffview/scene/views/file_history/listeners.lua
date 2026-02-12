local async = require("diffview.async")
local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api
local await = async.await

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_item[2]
      if file then
        view:set_file(file)
      end

      -- Restore panel cursor position.
      if view.panel_cursor and view.panel:is_open() then
        local winid = view.panel:get_winid()
        if winid and api.nvim_win_is_valid(winid) then
          pcall(api.nvim_win_set_cursor, winid, view.panel_cursor)
        end
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_item[2]

      -- Save panel cursor position.
      if view.panel:is_open() then
        local winid = view.panel:get_winid()
        if winid and api.nvim_win_is_valid(winid) then
          view.panel_cursor = api.nvim_win_get_cursor(winid)
        end
      end

      if file then
        file.layout:detach_files()
      end

      for _, entry in ipairs(view.panel.entries) do
        for _, f in ipairs(entry.files) do
          f.layout:restore_winopts()
        end
      end
    end,
    file_open_new = function(_, entry)
      utils.set_cursor(view.cur_layout:get_main_win().id, 1, 0)
      view.cur_layout:sync_scroll()
    end,
    open_in_diffview = function()
      local file = view:infer_cur_file()

      if file then
        local layout = file.layout --[[@as Diff2 ]]

        local new_view = DiffView({
          adapter = view.adapter,
          rev_arg = view.adapter:rev_to_pretty_string(layout.a.file.rev, layout.b.file.rev),
          left = layout.a.file.rev,
          right = layout.b.file.rev,
          options = { selected_file = file.absolute_path },
        })

        lib.add_view(new_view)
        new_view:open()
      end
    end,
    ---Open a diffview comparing HEAD with the commit under cursor.
    diff_against_head = function()
      local item = view.panel:get_item_at_cursor()
      if not item then return end

      local commit = item.commit or (item.entry and item.entry.commit)
      if not commit then return end

      local new_view = DiffView({
        adapter = view.adapter,
        rev_arg = commit.hash,
        left = view.adapter.Rev(RevType.COMMIT, commit.hash),
        right = view.adapter.Rev(RevType.LOCAL),
      })

      lib.add_view(new_view)
      new_view:open()
    end,
    select_next_entry = function()
      view:next_item()
    end,
    select_prev_entry = function()
      view:prev_item()
    end,
    select_first_entry = function()
      local entry = view.panel.entries[1]
      if entry and #entry.files > 0 then
        view:set_file(entry.files[1])
      end
    end,
    select_last_entry = function()
      local entry = view.panel.entries[#view.panel.entries]
      if entry and #entry.files > 0 then
        view:set_file(entry.files[#entry.files])
      end
    end,
    select_next_commit = function()
      local cur_entry = view.panel.cur_item[1]
      if not cur_entry then return end
      local entry_idx = utils.vec_indexof(view.panel.entries, cur_entry)
      if entry_idx == -1 then return end

      local next_idx = (entry_idx + vim.v.count1 - 1) % #view.panel.entries + 1
      local next_entry = view.panel.entries[next_idx]
      view:set_file(next_entry.files[1])
    end,
    select_prev_commit = function()
      local cur_entry = view.panel.cur_item[1]
      if not cur_entry then return end
      local entry_idx = utils.vec_indexof(view.panel.entries, cur_entry)
      if entry_idx == -1 then return end

      local next_idx = (entry_idx - vim.v.count1 - 1) % #view.panel.entries + 1
      local next_entry = view.panel.entries[next_idx]
      view:set_file(next_entry.files[1])
    end,
    ---Cycle to next file within the current commit (wrap around).
    next_entry_in_commit = function()
      local cur_entry = view.panel.cur_item[1]
      local cur_file = view.panel.cur_item[2]
      if not cur_entry or not cur_file then return end

      local file_idx = utils.vec_indexof(cur_entry.files, cur_file)
      if file_idx == -1 then return end

      local next_idx = (file_idx % #cur_entry.files) + 1
      view:set_file(cur_entry.files[next_idx])
    end,
    ---Cycle to previous file within the current commit (wrap around).
    prev_entry_in_commit = function()
      local cur_entry = view.panel.cur_item[1]
      local cur_file = view.panel.cur_item[2]
      if not cur_entry or not cur_file then return end

      local file_idx = utils.vec_indexof(cur_entry.files, cur_file)
      if file_idx == -1 then return end

      local prev_idx = ((file_idx - 2) % #cur_entry.files) + 1
      view:set_file(cur_entry.files[prev_idx])
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
              view.panel:toggle_entry_fold(item --[[@as LogEntry ]])
            end
          else
            view:set_file(item, false)
          end
        end
      elseif view.panel.option_panel:is_focused() then
        local option = view.panel.option_panel:get_item_at_cursor()
        if option then
          view.panel.option_panel.emitter:emit("set_option", option.key)
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
              view.panel:toggle_entry_fold(item --[[@as LogEntry ]])
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
          view.commit_log_panel:update(view.adapter.Rev.to_range(entry.commit.hash))
        end
      end
    end,
    focus_files = function()
      view.panel:focus()
    end,
    toggle_files = function()
      view.panel:toggle(true)
    end,
    refresh_files = function()
      view.panel:update_entries(function(_, status)
        if status >= JobStatus.ERROR then
          return
        end
        if not view:cur_file() then
          view:next_item()
        end
      end)
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
    open_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then return end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then view.panel:set_entry_fold(entry, true) end
    end,
    close_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then return end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then view.panel:set_entry_fold(entry, false) end
    end,
    toggle_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then return end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then view.panel:toggle_entry_fold(entry) end
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
          vim.fn.setreg('"', item.commit.hash)
          utils.info(string.format("Copied '%s' to the clipboard.", item.commit.hash))
        end
      end
    end,
    open_commit_in_browser = function()
      local item = view.panel:get_item_at_cursor()
      if not item then
        item = view.panel.cur_item[1]
      end
      if not item or not item.commit then return end

      local url = view.adapter:get_commit_url(item.commit.hash)
      if not url then
        utils.err("Could not construct browser URL. Remote URL not recognized.")
        return
      end

      local cmd
      if vim.fn.has("mac") == 1 then
        cmd = { "open", url }
      elseif vim.fn.has("wsl") == 1 then
        cmd = { "wslview", url }
      elseif vim.fn.has("unix") == 1 then
        cmd = { "xdg-open", url }
      elseif vim.fn.has("win32") == 1 then
        cmd = { "cmd", "/c", "start", '""', url }
      end

      if cmd then
        vim.fn.jobstart(cmd, { detach = true })
      end
    end,
    restore_entry = async.void(function()
      local item = view:infer_cur_file()
      if not item then return end

      local bufid = utils.find_file_buffer(item.path)

      if bufid and vim.bo[bufid].modified then
        utils.err("The file is open with unsaved changes! Aborting file restoration.")
        return
      end

      await(vcs_utils.restore_file(view.adapter, item.path, item.kind, item.commit.hash))
    end),
  }
end
