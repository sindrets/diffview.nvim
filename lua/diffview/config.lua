local M = {}

function M.diffview_callback(cb_name)
  return string.format(":lua require'diffview'.on_keypress('%s')<CR>", cb_name)
end

M.defaults = {
  file_panel = {
    width = 35
  },
  key_bindings = {
    view = {
      ["<tab>"]     = M.diffview_callback("next_file"),
      ["<s-tab>"]   = M.diffview_callback("prev_file"),
      ["<leader>e"] = M.diffview_callback("focus_files"),
      ["<leader>b"] = M.diffview_callback("toggle_files"),
    },
    file_panel = {
      ["j"]         = M.diffview_callback("next_node"),
      ["<down>"]    = M.diffview_callback("next_node"),
      ["k"]         = M.diffview_callback("prev_node"),
      ["<up>"]      = M.diffview_callback("prev_node"),
      ["<cr>"]      = M.diffview_callback("select_node"),
      ["<tab>"]     = M.diffview_callback("next_file"),
      ["<s-tab>"]   = M.diffview_callback("prev_file"),
      ["<leader>e"] = M.diffview_callback("focus_files"),
      ["<leader>b"] = M.diffview_callback("toggle_files"),
    }
  }
}

function M.get_config()
  -- TODO Implement config
  return M.defaults
end

return M
