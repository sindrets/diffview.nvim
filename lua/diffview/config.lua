local utils = require("diffview.utils")
local EventEmitter = require("diffview.events").EventEmitter
local M = {}

function M.diffview_callback(cb_name)
  return string.format("<Cmd>lua require'diffview'.trigger_event('%s')<CR>", cb_name)
end

local cb = M.diffview_callback

-- stylua: ignore start
M.defaults = {
  diff_binaries = false,
  enhanced_diff_hl = false,
  use_icons = true,
  icons = {
    folder_closed = "",
    folder_open = "",
  },
  signs = {
    fold_closed = "",
    fold_open = "",
  },
  file_panel = {
    listing_style = "tree",       -- One of 'list' or 'tree'
    tree_options = {              -- Only applies when listing_style is 'tree'
      flatten_dirs = true,
      folder_statuses = "only_folded"  -- One of 'never', 'only_folded' or 'always'.
    },
    win_config = {
      position = "left",
      width = 35,
    },
  },
  file_history_panel = {
    log_options = {
      max_count = 256,
      follow = false,
      all = false,
      merges = false,
      no_merges = false,
      reverse = false,
    },
    win_config = {
      position = "bottom",
      height = 16,
    },
  },
  commit_log_panel = {
    win_config = {},
  },
  default_args = {
    DiffviewOpen = {},
    DiffviewFileHistory = {},
  },
  hooks = {},
  key_bindings = {
    disable_defaults = false,
    view = {
      ["<tab>"]      = cb("select_next_entry"),
      ["<s-tab>"]    = cb("select_prev_entry"),
      ["gf"]         = cb("goto_file"),
      ["<C-w><C-f>"] = cb("goto_file_split"),
      ["<C-w>gf"]    = cb("goto_file_tab"),
      ["<leader>e"]  = cb("focus_files"),
      ["<leader>b"]  = cb("toggle_files"),
    },
    file_panel = {
      ["j"]             = cb("next_entry"),
      ["<down>"]        = cb("next_entry"),
      ["k"]             = cb("prev_entry"),
      ["<up>"]          = cb("prev_entry"),
      ["<cr>"]          = cb("select_entry"),
      ["o"]             = cb("select_entry"),
      ["<2-LeftMouse>"] = cb("select_entry"),
      ["-"]             = cb("toggle_stage_entry"),
      ["S"]             = cb("stage_all"),
      ["U"]             = cb("unstage_all"),
      ["X"]             = cb("restore_entry"),
      ["R"]             = cb("refresh_files"),
      ["L"]             = cb("open_commit_log"),
      ["<tab>"]         = cb("select_next_entry"),
      ["<s-tab>"]       = cb("select_prev_entry"),
      ["gf"]            = cb("goto_file"),
      ["<C-w><C-f>"]    = cb("goto_file_split"),
      ["<C-w>gf"]       = cb("goto_file_tab"),
      ["i"]             = cb("listing_style"),
      ["f"]             = cb("toggle_flatten_dirs"),
      ["<leader>e"]     = cb("focus_files"),
      ["<leader>b"]     = cb("toggle_files"),
    },
    file_history_panel = {
      ["g!"]            = cb("options"),
      ["<C-A-d>"]       = cb("open_in_diffview"),
      ["y"]             = cb("copy_hash"),
      ["L"]             = cb("open_commit_log"),
      ["zR"]            = cb("open_all_folds"),
      ["zM"]            = cb("close_all_folds"),
      ["j"]             = cb("next_entry"),
      ["<down>"]        = cb("next_entry"),
      ["k"]             = cb("prev_entry"),
      ["<up>"]          = cb("prev_entry"),
      ["<cr>"]          = cb("select_entry"),
      ["o"]             = cb("select_entry"),
      ["<2-LeftMouse>"] = cb("select_entry"),
      ["<tab>"]         = cb("select_next_entry"),
      ["<s-tab>"]       = cb("select_prev_entry"),
      ["gf"]            = cb("goto_file"),
      ["<C-w><C-f>"]    = cb("goto_file_split"),
      ["<C-w>gf"]       = cb("goto_file_tab"),
      ["<leader>e"]     = cb("focus_files"),
      ["<leader>b"]     = cb("toggle_files"),
    },
    option_panel = {
      ["<tab>"] = cb("select"),
      ["q"]     = cb("close"),
    },
  },
}
-- stylua: ignore end

---@type EventEmitter
M.user_emitter = EventEmitter()
M._config = M.defaults

function M.get_config()
  return M._config
end

function M.setup(user_config)
  user_config = user_config or {}

  M._config = utils.tbl_deep_clone(M.defaults)
  M._config = vim.tbl_deep_extend("force", M._config, user_config)
  ---@type EventEmitter
  M.user_emitter = EventEmitter()

  --#region DEPRECATION NOTICES

  if type(M._config.file_panel.use_icons) ~= "nil" then
    utils.warn("'file_panel.use_icons' has been deprecated. See ':h diffview.changelog-64'.")
  end

  local old_win_config_spec = { "position", "width", "height" }
  for _, panel_name in ipairs({ "file_panel", "file_history_panel" }) do
    local panel_config = M._config[panel_name]
    local notified = false

    for _, option in ipairs(old_win_config_spec) do
      if panel_config[option] ~= nil then
        if not notified then
          utils.warn(
            ("'%s.{position|width|height}' has been deprecated. See ':h diffview.changelog-136'.")
            :format(panel_name)
          )
          notified = true
        end
        panel_config.win_config[option] = panel_config[option]
        panel_config[option] = nil
      end
    end
  end

  --#endregion

  for event, callback in pairs(M._config.hooks) do
    if type(callback) == "function" then
      M.user_emitter:on(event, callback)
    end
  end

  if M._config.key_bindings.disable_defaults then
    for name, _ in pairs(M._config.key_bindings) do
      if name ~= "disable_defaults" then
        M._config.key_bindings[name] = (user_config.key_bindings and user_config.key_bindings[name])
          or {}
      end
    end
  end
end

return M
