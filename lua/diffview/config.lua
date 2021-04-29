local M = {}

function M.diffview_callback(cb_name)
  return string.format(":lua require'diffview'.on_keypress('%s')<CR>", cb_name)
end

M.defaults = {
  file_panel = {
    width = 30
  },
  key_bindings = {
    ["<tab>"]   = M.diffview_callback("next_file"),
    ["<s-tab>"] = M.diffview_callback("prev_file")
  }
}

function M.get_config()
  -- TODO Implement config
  return M.defaults
end

return M
