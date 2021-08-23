local api = vim.api

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
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
    win_leave = function()
      if view.ready and api.nvim_tabpage_is_valid(view.tabpage) then
        view:fix_foreign_windows()
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
          view:set_file(file, true)
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
