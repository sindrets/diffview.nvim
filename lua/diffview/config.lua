---@diagnostic disable: deprecated
local EventEmitter = require("diffview.events").EventEmitter
local actions = require("diffview.actions")
local lazy = require("diffview.lazy")

---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local M = {}

---@deprecated
function M.diffview_callback(cb_name)
  if cb_name == "select" then
    -- Reroute deprecated action
    return actions.select_entry
  end
  return actions[cb_name]
end

---@class ConfigLogOptions
---@field single_file LogOptions
---@field multi_file LogOptions

-- stylua: ignore start
M.defaults = {
  diff_binaries = false,
  enhanced_diff_hl = false,
  git_cmd = { "git" },
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
    listing_style = "tree",
    tree_options = {
      flatten_dirs = true,
      folder_statuses = "only_folded"
    },
    win_config = {
      position = "left",
      width = 35,
    },
  },
  file_history_panel = {
    ---@type ConfigLogOptions
    log_options = {
      single_file = {
        diff_merges = "combined",
      },
      multi_file = {
        diff_merges = "first-parent",
      },
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
  keymaps = {
    disable_defaults = false,
    view = {
      ["<tab>"]      = actions.select_next_entry,
      ["<s-tab>"]    = actions.select_prev_entry,
      ["gf"]         = actions.goto_file,
      ["<C-w><C-f>"] = actions.goto_file_split,
      ["<C-w>gf"]    = actions.goto_file_tab,
      ["<leader>e"]  = actions.focus_files,
      ["<leader>b"]  = actions.toggle_files,
    },
    file_panel = {
      ["j"]             = actions.next_entry,
      ["<down>"]        = actions.next_entry,
      ["k"]             = actions.prev_entry,
      ["<up>"]          = actions.prev_entry,
      ["<cr>"]          = actions.select_entry,
      ["o"]             = actions.select_entry,
      ["<2-LeftMouse>"] = actions.select_entry,
      ["-"]             = actions.toggle_stage_entry,
      ["S"]             = actions.stage_all,
      ["U"]             = actions.unstage_all,
      ["X"]             = actions.restore_entry,
      ["R"]             = actions.refresh_files,
      ["L"]             = actions.open_commit_log,
      ["<c-b>"]         = actions.scroll_view(-0.25),
      ["<c-f>"]         = actions.scroll_view(0.25),
      ["<tab>"]         = actions.select_next_entry,
      ["<s-tab>"]       = actions.select_prev_entry,
      ["gf"]            = actions.goto_file,
      ["<C-w><C-f>"]    = actions.goto_file_split,
      ["<C-w>gf"]       = actions.goto_file_tab,
      ["i"]             = actions.listing_style,
      ["f"]             = actions.toggle_flatten_dirs,
      ["<leader>e"]     = actions.focus_files,
      ["<leader>b"]     = actions.toggle_files,
    },
    file_history_panel = {
      ["g!"]            = actions.options,
      ["<C-A-d>"]       = actions.open_in_diffview,
      ["y"]             = actions.copy_hash,
      ["L"]             = actions.open_commit_log,
      ["zR"]            = actions.open_all_folds,
      ["zM"]            = actions.close_all_folds,
      ["j"]             = actions.next_entry,
      ["<down>"]        = actions.next_entry,
      ["k"]             = actions.prev_entry,
      ["<up>"]          = actions.prev_entry,
      ["<cr>"]          = actions.select_entry,
      ["o"]             = actions.select_entry,
      ["<2-LeftMouse>"] = actions.select_entry,
      ["<c-b>"]         = actions.scroll_view(-0.25),
      ["<c-f>"]         = actions.scroll_view(0.25),
      ["<tab>"]         = actions.select_next_entry,
      ["<s-tab>"]       = actions.select_prev_entry,
      ["gf"]            = actions.goto_file,
      ["<C-w><C-f>"]    = actions.goto_file_split,
      ["<C-w>gf"]       = actions.goto_file_tab,
      ["<leader>e"]     = actions.focus_files,
      ["<leader>b"]     = actions.toggle_files,
    },
    option_panel = {
      ["<tab>"] = actions.select_entry,
      ["q"]     = actions.close,
    },
  },
}
-- stylua: ignore end

---@type EventEmitter
M.user_emitter = EventEmitter()
M._config = M.defaults

---@class LogOptions
---@field follow boolean
---@field first_parent boolean
---@field show_pulls boolean
---@field reflog boolean
---@field all boolean
---@field merges boolean
---@field no_merges boolean
---@field reverse boolean
---@field max_count integer
---@field L string[]
---@field author string
---@field grep string
---@field diff_merges string
---@field rev_range string

---@type LogOptions
M.log_option_defaults = {
  follow = false,
  first_parent = false,
  show_pulls = false,
  reflog = false,
  all = false,
  merges = false,
  no_merges = false,
  reverse = false,
  rev_range = nil,
  max_count = 256,
  L = {},
  diff_merges = nil,
  author = nil,
  grep = nil,
}

function M.get_config()
  return M._config
end

---@param single_file boolean
---@param t LogOptions
---@return LogOptions
function M.get_log_options(single_file, t)
  local log_options

  if single_file then
    log_options =  M._config.file_history_panel.log_options.single_file
  else
    log_options = M._config.file_history_panel.log_options.multi_file
  end

  if t then
    log_options = vim.tbl_extend("force", log_options, t)

    for k, _ in pairs(log_options) do
      if t[k] == "" then
        log_options[k] = nil
      end
    end
  end

  return log_options
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

  -- Move old panel preoperties to win_config
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

  -- Move old keymaps
  if user_config.key_bindings then
    M._config.keymaps = vim.tbl_deep_extend("force", M._config.keymaps, user_config.key_bindings)
    user_config.keymaps = user_config.key_bindings
    M._config.key_bindings = nil
  end

  local user_log_options = utils.tbl_access(user_config, "file_history_panel.log_options")
  if user_log_options then
    local option_names = {
      "max_count",
      "follow",
      "all",
      "merges",
      "no_merges",
      "reverse",
    }
    for _, name in ipairs(option_names) do
      if user_log_options[name] ~= nil then
        utils.warn(
          ("'file_history_panel.log_options.(%s)' has been deprecated. See ':h diffview.changelog-151'.")
          :format(table.concat(option_names, "|"))
        )
        break
      end
    end
  end

  --#endregion

  if #M._config.git_cmd == 0 then
    M._config.git_cmd = M.defaults.git_cmd
  end

  for _, name in ipairs({ "single_file", "multi_file" }) do
    local t = M._config.file_history_panel.log_options
    t[name] = vim.tbl_extend(
      "force",
      M.log_option_defaults,
      t[name]
    )
    for k, _ in pairs(t[name]) do
      if t[name][k] == "" then
        t[name][k] = nil
      end
    end
  end

  for event, callback in pairs(M._config.hooks) do
    if type(callback) == "function" then
      M.user_emitter:on(event, callback)
    end
  end

  if M._config.keymaps.disable_defaults then
    for name, _ in pairs(M._config.keymaps) do
      if name ~= "disable_defaults" then
        M._config.keymaps[name] = utils.tbl_access(user_config, "keymaps." .. name) or {}
      end
    end
  end

  -- Disable keymaps set to `false`
  for name, keymaps in pairs(M._config.keymaps) do
    if type(name) == "string" and type(keymaps) == "table" then
      for lhs, rhs in pairs(keymaps) do
        if type(lhs) == "string" and type(rhs) == "boolean" and not rhs then
          keymaps[lhs] = nil
        end
      end
    end
  end
end

M.actions = actions
return M
