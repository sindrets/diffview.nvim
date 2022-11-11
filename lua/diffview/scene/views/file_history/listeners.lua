local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_item[2]
      if file then
        view:set_file(file)
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_item[2]

      if file then
        file.layout:detach_files()
      end

      for _, entry in ipairs(view.panel.entries) do
        for _, f in ipairs(entry.files) do
          f.layout:restore_winopts()
        end
      end
    end,
    diff_buf_read = function(bufnr)
      -- Set the cursor at the beginning of the -L range if possible.

      local log_options = view.panel:get_log_options()
      local cur = view.panel:cur_file()

      if log_options.L[1] and bufnr == cur.layout:get_main_win().file.bufnr then
        for _, value in ipairs(log_options.L) do
          local l1, lpath = value:match("^(%d+),.*:(.*)")

          if l1 then
            l1 = tonumber(l1)
            lpath = utils.path:chain(lpath)
                :normalize({ cwd = view.adapter.ctx.toplevel, absolute = true })
                :relative(view.adapter.ctx.toplevel)
                :get()

            if lpath == cur.path then
              utils.set_cursor(0, l1, 0)
              vim.cmd("norm! zt")
              break
            end
          end
        end
      else
        utils.set_cursor(0, 1, 0)
      end
    end,
    open_in_diffview = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          local file

          if item.files then
            file = item.files[1]
          else
            file = item --[[@as FileEntry ]]
          end

          if file then
            local layout = file.layout --[[@as Diff2 ]]

            local new_view = DiffView({
              adapter = view.adapter,
              rev_arg = view.adapter:rev_to_pretty_string(layout.a.file.rev, layout.b.file.rev),
              left = layout.a.file.rev,
              right = layout.b.file.rev,
              options = {},
            }) --[[@as DiffView ]]

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
