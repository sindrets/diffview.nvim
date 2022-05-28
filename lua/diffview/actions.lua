local utils = require("diffview.utils")

local api = vim.api

local M = setmetatable({}, {
  __index = function(_, k)
    utils.err((
      "The action '%s' does not exist! "
      .. "See ':h diffview-available-actions' for an overview of available actions."
    ):format(k))
  end
})

---Execute `cmd` for each target window in the current view. If no targets
---are given, all windows are targeted.
---@param cmd string The vim cmd to execute.
---@param targets? { left: boolean, right: boolean } The windows to target.
---@return function action
function M.view_windo(cmd, targets)
  return function()
    local view = require("diffview.lib").get_current_view()
    if view then
      targets = targets or { left = true, right = true }
      for _, side in ipairs({ "left", "right" }) do
        if targets[side] then
          api.nvim_win_call(view[side .. "_winid"], function()
            vim.cmd(cmd)
          end)
        end
      end
    end
  end
end

---@param distance number Either an exact number of lines, or a fraction of the window height.
---@return function
function M.scroll_view(distance)
  local scroll_opr = distance < 0 and [[\<c-y>]] or [[\<c-e>]]
  local scroll_cmd

  if distance % 1 == 0 then
    scroll_cmd = ([[exe "norm! %d%s"]]):format(distance, scroll_opr)
  else
    scroll_cmd = ([[exe "norm! " . float2nr(winheight(0) * %f) . "%s"]])
        :format(distance, scroll_opr)
  end

  return M.view_windo(scroll_cmd, { right = true })
end

local action_names = {
  "close",
  "close_all_folds",
  "copy_hash",
  "focus_entry",
  "focus_files",
  "goto_file",
  "goto_file_edit",
  "goto_file_split",
  "goto_file_tab",
  "listing_style",
  "next_entry",
  "open_all_folds",
  "open_commit_log",
  "open_in_diffview",
  "options",
  "prev_entry",
  "refresh_files",
  "restore_entry",
  "select_entry",
  "select_next_entry",
  "select_prev_entry",
  "stage_all",
  "toggle_files",
  "toggle_flatten_dirs",
  "toggle_stage_entry",
  "unstage_all",
}

for _, name in ipairs(action_names) do
  M[name] = function()
    require("diffview").emit(name)
  end
end

return M
