---@diagnostic disable: deprecated
local EventEmitter = require("diffview.events").EventEmitter
local actions = require("diffview.actions")
local lazy = require("diffview.lazy")

---@module "diffview.utils"
local utils = lazy.require("diffview.utils")
---@type Diff1|LazyModule
local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1")
---@type Diff2|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2")
---@type Diff2Hor|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor")
---@type Diff2Ver|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver")
---@type Diff3|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3")
---@type Diff3Hor|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor")
---@type Diff3Hor|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver")
---@type Diff3Mixed|LazyModule
local Diff3Mixed = lazy.access("diffview.scene.layouts.diff_3_mixed", "Diff3Mixed")
---@type Diff4|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4")
---@type Diff4Mixed|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed")

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
---@class DiffviewConfig
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
    done = "✓",
  },
  view = {
    default = {
      layout = "diff2_horizontal",
    },
    merge_tool = {
      layout = "diff3_horizontal",
      disable_diagnostics = true,
    },
    file_history = {
      layout = "diff2_horizontal",
    },
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
      win_opts = {}
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
      win_opts = {}
    },
  },
  commit_log_panel = {
    win_config = {
      win_opts = {}
    },
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
      ["g<C-x>"]     = actions.cycle_layout,
      ["[x"]         = actions.prev_conflict,
      ["]x"]         = actions.next_conflict,
      ["<leader>co"] = actions.conflict_choose("ours"),
      ["<leader>ct"] = actions.conflict_choose("theirs"),
      ["<leader>cb"] = actions.conflict_choose("base"),
      ["<leader>ca"] = actions.conflict_choose("all"),
      ["dx"]         = actions.conflict_choose("none"),
    },
    diff1 = {},
    diff2 = {},
    diff3 = {
      { { "n", "x" }, "2do", actions.diffget("ours") },
      { { "n", "x" }, "3do", actions.diffget("theirs") },
    },
    diff4 = {
      { { "n", "x" }, "1do", actions.diffget("base") },
      { { "n", "x" }, "2do", actions.diffget("ours") },
      { { "n", "x" }, "3do", actions.diffget("theirs") },
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
      ["g<C-x>"]        = actions.cycle_layout,
      ["[x"]            = actions.prev_conflict,
      ["]x"]            = actions.next_conflict,
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
      ["g<C-x>"]        = actions.cycle_layout,
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

---@return DiffviewConfig
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

---@alias LayoutName "diff1_plain"
---       | "diff2_horizontal"
---       | "diff2_vertical"
---       | "diff3_horizontal"
---       | "diff3_vertical"
---       | "diff3_mixed"
---       | "diff4_mixed"

local layout_map = {
  diff1_plain = Diff1,
  diff2_horizontal = Diff2Hor,
  diff2_vertical = Diff2Ver,
  diff3_horizontal = Diff3Hor,
  diff3_vertical = Diff3Ver,
  diff3_mixed = Diff3Mixed,
  diff4_mixed = Diff4Mixed,
}

---@param layout_name LayoutName
---@return Layout
function M.name_to_layout(layout_name)
  assert(layout_map[layout_name], "Invalid layout name: " .. layout_name)

  return layout_map[layout_name].__get()
end

---@param layout Layout
---@return table?
function M.get_layout_keymaps(layout)
  if layout:instanceof(Diff1.__get()) then
    return M._config.keymaps.diff1
  elseif layout:instanceof(Diff2.__get()) then
    return M._config.keymaps.diff2
  elseif layout:instanceof(Diff3.__get()) then
    return M._config.keymaps.diff3
  elseif layout:instanceof(Diff4.__get()) then
    return M._config.keymaps.diff4
  end
end

---@param values vector
---@param no_quote? boolean
---@return string
local function fmt_enum(values, no_quote)
  return table.concat(vim.tbl_map(function(v)
    return (not no_quote and type(v) == "string") and ("'" .. v .. "'") or v
  end, values), "|")
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
      ---@cast panel_config table
    local notified = false

    for _, option in ipairs(old_win_config_spec) do
      if panel_config[option] ~= nil then
        if not notified then
          utils.warn(
            ("'%s.{%s}' has been deprecated. See ':h diffview.changelog-136'.")
            :format(panel_name, fmt_enum(old_win_config_spec, true))
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
          ("'file_history_panel.log_options.{%s}' has been deprecated. See ':h diffview.changelog-151'.")
          :format(fmt_enum(option_names, true))
        )
        break
      end
    end
  end

  --#endregion

  if #M._config.git_cmd == 0 then
    M._config.git_cmd = M.defaults.git_cmd
  end

  do
    -- Validate layouts
    local view = M._config.view
    local standard_layouts = { "diff2_horizontal", "diff2_vertical", -1 }
    local merge_layuots = {
      "diff1_plain",
      "diff3_horizontal",
      "diff3_vertical",
      "diff3_mixed",
      "diff4_mixed",
      -1
    }
    local valid_layouts = {
      default = standard_layouts,
      merge_tool = merge_layuots,
      file_history = standard_layouts,
    }

    for _, kind in ipairs(vim.tbl_keys(valid_layouts)) do
      if not vim.tbl_contains(valid_layouts[kind], view[kind].layout) then
        utils.err(("Invalid layout name '%s' for 'view.%s'! Must be one of (%s)."):format(
          view[kind].layout,
          kind,
          fmt_enum(valid_layouts[kind])
        ))
        view[kind].layout = M.defaults.view[kind].layout
      end
    end
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
