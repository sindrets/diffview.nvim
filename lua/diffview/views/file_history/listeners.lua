local api = vim.api

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_item[2]
      if file then
        file:attach_buffers()
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_item[2]
      if file then
        file:detach_buffers()
      end
    end,
    buf_new = function()
      if view.ready and api.nvim_tabpage_is_valid(view.tabpage) then
        vim.schedule(function ()
          view:fix_foreign_windows()
        end)
      end
    end,
    cursor_hold = function()
      if view.ready and api.nvim_tabpage_is_valid(view.tabpage) then
        vim.schedule(function ()
          view:fix_foreign_windows()
        end)
      end
    end,
    win_leave = function()
      if view.ready and api.nvim_tabpage_is_valid(view.tabpage) then
        view:fix_foreign_windows()
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
      if view.panel:is_open() then
        local item = view.panel:get_item_at_cursor()
        if item then
          -- print(vim.inspect(item))
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
    focus_files = function()
      view.panel:focus(true)
    end,
    toggle_files = function()
      view.panel:toggle()
    end,
  }
end
