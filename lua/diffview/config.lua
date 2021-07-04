local utils = require'diffview.utils'
local M = {}

function M.diffview_callback(cb_name)
  return string.format("<Cmd>lua require'diffview'.on_keypress('%s')<CR>", cb_name)
end

M.defaults = {
  diff_binaries = false,
  file_panel = {
    width = 35,
    use_icons = true
  },
  key_bindings = {
    disable_defaults = false,
    view = {
      ["<tab>"]     = M.diffview_callback("select_next_entry"),
      ["<s-tab>"]   = M.diffview_callback("select_prev_entry"),
      ["<leader>e"] = M.diffview_callback("focus_files"),
      ["<leader>b"] = M.diffview_callback("toggle_files"),
    },
    file_panel = {
      ["j"]             = M.diffview_callback("next_entry"),
      ["<down>"]        = M.diffview_callback("next_entry"),
      ["k"]             = M.diffview_callback("prev_entry"),
      ["<up>"]          = M.diffview_callback("prev_entry"),
      ["<cr>"]          = M.diffview_callback("select_entry"),
      ["o"]             = M.diffview_callback("select_entry"),
      ["<2-LeftMouse>"] = M.diffview_callback("select_entry"),
      ["-"]             = M.diffview_callback("toggle_stage_entry"),
      ["S"]             = M.diffview_callback("stage_all"),
      ["U"]             = M.diffview_callback("unstage_all"),
      ["R"]             = M.diffview_callback("refresh_files"),
      ["<tab>"]         = M.diffview_callback("select_next_entry"),
      ["<s-tab>"]       = M.diffview_callback("select_prev_entry"),
      ["<leader>e"]     = M.diffview_callback("focus_files"),
      ["<leader>b"]     = M.diffview_callback("toggle_files"),
    }
  }
}

M._config = M.defaults

function M.get_config()
  return M._config
end

function M.setup(user_config)
  user_config = user_config or {}
  M._config = utils.tbl_deep_clone(M.defaults)
  M._config = vim.tbl_deep_extend("force", M._config, user_config)

  if M._config.key_bindings.disable_defaults then
    M._config.key_bindings.view =
      (user_config.key_bindings and user_config.key_bindings.view) or {}
    M._config.key_bindings.file_panel =
      (user_config.key_bindings and user_config.key_bindings.file_panel) or {}
  end
end

return M
