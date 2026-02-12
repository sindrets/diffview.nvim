require("diffview.bootstrap")

---@diagnostic disable: deprecated
local EventEmitter = require("diffview.events").EventEmitter
local actions = require("diffview.actions")
local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") ---@type Diff2Hor|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") ---@type Diff2Ver|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff3Mixed = lazy.access("diffview.scene.layouts.diff_3_mixed", "Diff3Mixed") ---@type Diff3Mixed|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver") ---@type Diff3Hor|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

local setup_done = false

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
  hg_cmd = { "hg" },
  rename_threshold = nil, -- Similarity threshold for rename detection (e.g. 40 for 40%). Nil uses git default (50%).
  use_icons = true,
  show_help_hints = true,
  watch_index = true,
  hide_merge_artifacts = false, -- Hide merge artifact files (*.orig, *.BACKUP.*, etc.)
  auto_close_on_empty = false, -- Automatically close diffview when the last file is staged/resolved.
  -- Override diffopt settings while diffview is open. Restored on close.
  -- Keys: algorithm, context, indent_heuristic, iwhite, iwhiteall, iwhiteeol, iblank, icase.
  -- Example: { algorithm = "histogram", indent_heuristic = true }
  diffopt = {},
  clean_up_buffers = false, -- Delete file buffers created by diffview on close (only buffers not open before diffview).
  icons = {
    folder_closed = "",
    folder_open = "",
  },
  status_icons = {
    ["A"] = "A",  -- Added
    ["?"] = "?",  -- Untracked
    ["M"] = "M",  -- Modified
    ["R"] = "R",  -- Renamed
    ["C"] = "C",  -- Copied
    ["T"] = "T",  -- Type changed
    ["U"] = "U",  -- Unmerged
    ["X"] = "X",  -- Unknown
    ["D"] = "D",  -- Deleted
    ["B"] = "B",  -- Broken
    ["!"] = "!",  -- Ignored
  },
  signs = {
    fold_closed = "",
    fold_open = "",
    done = "✓",
  },
  view = {
    default = {
      layout = "diff2_horizontal",
      disable_diagnostics = false,
      winbar_info = false,
    },
    merge_tool = {
      layout = "diff3_horizontal",
      disable_diagnostics = true,
      winbar_info = true,
    },
    file_history = {
      layout = "diff2_horizontal",
      disable_diagnostics = false,
      winbar_info = false,
    },
    -- Layouts to cycle through with `cycle_layout` action.
    cycle_layouts = {
      default = { "diff2_horizontal", "diff2_vertical" },
      merge_tool = { "diff3_horizontal", "diff3_vertical", "diff3_mixed", "diff4_mixed", "diff1_plain" },
    },
  },
  file_panel = {
    listing_style = "tree",
    sort_file = nil, -- Custom file comparator: function(a_name, b_name, a_data, b_data) -> boolean
    tree_options = {
      flatten_dirs = true,
      folder_statuses = "only_folded"
    },
    win_config = {
      position = "left",
      width = 35,
      win_opts = {}
    },
    show = true, -- Show the file panel by default when opening Diffview.
    always_show_sections = false, -- Always show Changes and Staged changes sections even when empty.
    show_branch_name = false, -- Show branch name in the file panel header.
  },
  file_history_panel = {
    stat_style = "number", -- "number" (e.g. "5, 3"), "bar" (e.g. "| 8 +++++---"), or "both".
    -- Ordered list of components to show for each commit entry.
    -- Available: "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date"
    commit_format = { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },
    log_options = {
      ---@type ConfigLogOptions
      git = {
        single_file = {
          diff_merges = "first-parent",
          follow = true,
        },
        multi_file = {
          diff_merges = "first-parent",
        },
      },
      ---@type ConfigLogOptions
      hg = {
        single_file = {},
        multi_file = {},
      },
    },
    win_config = {
      position = "bottom",
      height = 16,
      win_opts = {}
    },
    commit_subject_max_length = 72, -- Max length for commit subject display.
    date_format = "auto", -- Date format: "auto" (relative for recent, ISO for old), "relative", or "iso".
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
  -- Tabularize formatting pattern: `\v(\"[^"]{-}\",\ze(\s*)actions)|actions\.\w+(\(.{-}\))?,?|\{\ desc\ \=`
  keymaps = {
    disable_defaults = false, -- Disable the default keymaps
    view = {
      -- The `view` bindings are active in the diff buffers, only when the current
      -- tabpage is a Diffview.
      { "n", "<tab>",       actions.select_next_entry,              { desc = "Open the diff for the next file" } },
      { "n", "<s-tab>",     actions.select_prev_entry,              { desc = "Open the diff for the previous file" } },
      { "n", "[F",          actions.select_first_entry,             { desc = "Open the diff for the first file" } },
      { "n", "]F",          actions.select_last_entry,              { desc = "Open the diff for the last file" } },
      { "n", "gf",          actions.goto_file_edit,                 { desc = "Open the file in the previous tabpage" } },
      { "n", "<C-w><C-f>",  actions.goto_file_split,                { desc = "Open the file in a new split" } },
      { "n", "<C-w>gf",     actions.goto_file_tab,                  { desc = "Open the file in a new tabpage" } },
      { "n", "gx",          actions.open_file_external,             { desc = "Open the file with default system application" } },
      { "n", "<C-w>T",      actions.open_in_new_tab,                { desc = "Open diffview in a new tab" } },
      { "n", "<leader>e",   actions.focus_files,                    { desc = "Bring focus to the file panel" } },
      { "n", "<leader>b",   actions.toggle_files,                   { desc = "Toggle the file panel" } },
      { "n", "g<C-x>",      actions.cycle_layout,                   { desc = "Cycle through available layouts" } },
      { "n", "[x",          actions.prev_conflict,                  { desc = "In the merge-tool: jump to the previous conflict" } },
      { "n", "]x",          actions.next_conflict,                  { desc = "In the merge-tool: jump to the next conflict" } },
      { "n", "<leader>co",  actions.conflict_choose("ours"),        { desc = "Choose the OURS version of a conflict" } },
      { "n", "<leader>ct",  actions.conflict_choose("theirs"),      { desc = "Choose the THEIRS version of a conflict" } },
      { "n", "<leader>cb",  actions.conflict_choose("base"),        { desc = "Choose the BASE version of a conflict" } },
      { "n", "<leader>ca",  actions.conflict_choose("all"),         { desc = "Choose all the versions of a conflict" } },
      { "n", "dx",          actions.conflict_choose("none"),        { desc = "Delete the conflict region" } },
      { "n", "<leader>cO",  actions.conflict_choose_all("ours"),    { desc = "Choose the OURS version of a conflict for the whole file" } },
      { "n", "<leader>cT",  actions.conflict_choose_all("theirs"),  { desc = "Choose the THEIRS version of a conflict for the whole file" } },
      { "n", "<leader>cB",  actions.conflict_choose_all("base"),    { desc = "Choose the BASE version of a conflict for the whole file" } },
      { "n", "<leader>cA",  actions.conflict_choose_all("all"),     { desc = "Choose all the versions of a conflict for the whole file" } },
      { "n", "dX",          actions.conflict_choose_all("none"),    { desc = "Delete the conflict region for the whole file" } },
      unpack(actions.compat.fold_cmds),
    },
    diff1 = {
      -- Mappings in single window diff layouts
      { "n", "g?", actions.help({ "view", "diff1" }), { desc = "Open the help panel" } },
    },
    diff2 = {
      -- Mappings in 2-way diff layouts
      { "n", "g?", actions.help({ "view", "diff2" }), { desc = "Open the help panel" } },
    },
    diff3 = {
      -- Mappings in 3-way diff layouts
      { { "n", "x" }, "2do",  actions.diffget("ours"),            { desc = "Obtain the diff hunk from the OURS version of the file" } },
      { { "n", "x" }, "3do",  actions.diffget("theirs"),          { desc = "Obtain the diff hunk from the THEIRS version of the file" } },
      { "n",          "g?",   actions.help({ "view", "diff3" }),  { desc = "Open the help panel" } },
    },
    diff4 = {
      -- Mappings in 4-way diff layouts
      { { "n", "x" }, "1do",  actions.diffget("base"),            { desc = "Obtain the diff hunk from the BASE version of the file" } },
      { { "n", "x" }, "2do",  actions.diffget("ours"),            { desc = "Obtain the diff hunk from the OURS version of the file" } },
      { { "n", "x" }, "3do",  actions.diffget("theirs"),          { desc = "Obtain the diff hunk from the THEIRS version of the file" } },
      { "n",          "g?",   actions.help({ "view", "diff4" }),  { desc = "Open the help panel" } },
    },
    file_panel = {
      { "n", "j",              actions.next_entry,                     { desc = "Bring the cursor to the next file entry" } },
      { "n", "<down>",         actions.next_entry,                     { desc = "Bring the cursor to the next file entry" } },
      { "n", "k",              actions.prev_entry,                     { desc = "Bring the cursor to the previous file entry" } },
      { "n", "<up>",           actions.prev_entry,                     { desc = "Bring the cursor to the previous file entry" } },
      { "n", "<cr>",           actions.select_entry,                   { desc = "Open the diff for the selected entry" } },
      { "n", "o",              actions.select_entry,                   { desc = "Open the diff for the selected entry" } },
      { "n", "l",              actions.select_entry,                   { desc = "Open the diff for the selected entry" } },
      { "n", "<2-LeftMouse>",  actions.select_entry,                   { desc = "Open the diff for the selected entry" } },
      { "n", "-",              actions.toggle_stage_entry,             { desc = "Stage / unstage the selected entry" } },
      { "n", "s",              actions.toggle_stage_entry,             { desc = "Stage / unstage the selected entry" } },
      { "n", "S",              actions.stage_all,                      { desc = "Stage all entries" } },
      { "n", "U",              actions.unstage_all,                    { desc = "Unstage all entries" } },
      { "n", "X",              actions.restore_entry,                  { desc = "Restore entry to the state on the left side" } },
      { "n", "L",              actions.open_commit_log,                { desc = "Open the commit log panel" } },
      { "n", "zo",             actions.open_fold,                      { desc = "Expand fold" } },
      { "n", "h",              actions.close_fold,                     { desc = "Collapse fold" } },
      { "n", "zc",             actions.close_fold,                     { desc = "Collapse fold" } },
      { "n", "za",             actions.toggle_fold,                    { desc = "Toggle fold" } },
      { "n", "zR",             actions.open_all_folds,                 { desc = "Expand all folds" } },
      { "n", "zM",             actions.close_all_folds,                { desc = "Collapse all folds" } },
      { "n", "<c-b>",          actions.scroll_view(-0.25),             { desc = "Scroll the view up" } },
      { "n", "<c-f>",          actions.scroll_view(0.25),              { desc = "Scroll the view down" } },
      { "n", "<tab>",          actions.select_next_entry,              { desc = "Open the diff for the next file" } },
      { "n", "<s-tab>",        actions.select_prev_entry,              { desc = "Open the diff for the previous file" } },
      { "n", "[F",             actions.select_first_entry,             { desc = "Open the diff for the first file" } },
      { "n", "]F",             actions.select_last_entry,              { desc = "Open the diff for the last file" } },
      { "n", "gf",             actions.goto_file_edit,                 { desc = "Open the file in the previous tabpage" } },
      { "n", "<C-w><C-f>",     actions.goto_file_split,                { desc = "Open the file in a new split" } },
      { "n", "<C-w>gf",        actions.goto_file_tab,                  { desc = "Open the file in a new tabpage" } },
      { "n", "gx",             actions.open_file_external,             { desc = "Open the file with default system application" } },
      { "n", "<C-w>T",        actions.open_in_new_tab,                { desc = "Open diffview in a new tab" } },
      { "n", "i",              actions.listing_style,                  { desc = "Toggle between 'list' and 'tree' views" } },
      { "n", "f",              actions.toggle_flatten_dirs,            { desc = "Flatten empty subdirectories in tree listing style" } },
      { "n", "R",              actions.refresh_files,                  { desc = "Update stats and entries in the file list" } },
      { "n", "<leader>e",      actions.focus_files,                    { desc = "Bring focus to the file panel" } },
      { "n", "<leader>b",      actions.toggle_files,                   { desc = "Toggle the file panel" } },
      { "n", "g<C-x>",         actions.cycle_layout,                   { desc = "Cycle available layouts" } },
      { "n", "[x",             actions.prev_conflict,                  { desc = "Go to the previous conflict" } },
      { "n", "]x",             actions.next_conflict,                  { desc = "Go to the next conflict" } },
      { "n", "g?",             actions.help("file_panel"),             { desc = "Open the help panel" } },
      { "n", "<leader>cO",     actions.conflict_choose_all("ours"),    { desc = "Choose the OURS version of a conflict for the whole file" } },
      { "n", "<leader>cT",     actions.conflict_choose_all("theirs"),  { desc = "Choose the THEIRS version of a conflict for the whole file" } },
      { "n", "<leader>cB",     actions.conflict_choose_all("base"),    { desc = "Choose the BASE version of a conflict for the whole file" } },
      { "n", "<leader>cA",     actions.conflict_choose_all("all"),     { desc = "Choose all the versions of a conflict for the whole file" } },
      { "n", "dX",             actions.conflict_choose_all("none"),    { desc = "Delete the conflict region for the whole file" } },
    },
    file_history_panel = {
      { "n", "g!",            actions.options,                     { desc = "Open the option panel" } },
      { "n", "<C-A-d>",       actions.open_in_diffview,            { desc = "Open the entry under the cursor in a diffview" } },
      { "n", "H",             actions.diff_against_head,           { desc = "Open a diffview comparing HEAD with the commit under the cursor" } },
      { "n", "y",             actions.copy_hash,                   { desc = "Copy the commit hash of the entry under the cursor" } },
      { "n", "L",             actions.open_commit_log,             { desc = "Show commit details" } },
      { "n", "X",             actions.restore_entry,               { desc = "Restore file to the state from the selected entry" } },
      { "n", "zo",            actions.open_fold,                   { desc = "Expand fold" } },
      { "n", "zc",            actions.close_fold,                  { desc = "Collapse fold" } },
      { "n", "h",             actions.close_fold,                  { desc = "Collapse fold" } },
      { "n", "za",            actions.toggle_fold,                 { desc = "Toggle fold" } },
      { "n", "zR",            actions.open_all_folds,              { desc = "Expand all folds" } },
      { "n", "zM",            actions.close_all_folds,             { desc = "Collapse all folds" } },
      { "n", "j",             actions.next_entry,                  { desc = "Bring the cursor to the next file entry" } },
      { "n", "<down>",        actions.next_entry,                  { desc = "Bring the cursor to the next file entry" } },
      { "n", "k",             actions.prev_entry,                  { desc = "Bring the cursor to the previous file entry" } },
      { "n", "<up>",          actions.prev_entry,                  { desc = "Bring the cursor to the previous file entry" } },
      { "n", "<cr>",          actions.select_entry,                { desc = "Open the diff for the selected entry" } },
      { "n", "o",             actions.select_entry,                { desc = "Open the diff for the selected entry" } },
      { "n", "l",             actions.select_entry,                { desc = "Open the diff for the selected entry" } },
      { "n", "<2-LeftMouse>", actions.select_entry,                { desc = "Open the diff for the selected entry" } },
      { "n", "<c-b>",         actions.scroll_view(-0.25),          { desc = "Scroll the view up" } },
      { "n", "<c-f>",         actions.scroll_view(0.25),           { desc = "Scroll the view down" } },
      { "n", "<tab>",         actions.select_next_entry,           { desc = "Open the diff for the next file" } },
      { "n", "<s-tab>",       actions.select_prev_entry,           { desc = "Open the diff for the previous file" } },
      { "n", "[F",            actions.select_first_entry,          { desc = "Open the diff for the first file" } },
      { "n", "]F",            actions.select_last_entry,           { desc = "Open the diff for the last file" } },
      { "n", "gf",            actions.goto_file_edit,              { desc = "Open the file in the previous tabpage" } },
      { "n", "<C-w><C-f>",    actions.goto_file_split,             { desc = "Open the file in a new split" } },
      { "n", "<C-w>gf",       actions.goto_file_tab,               { desc = "Open the file in a new tabpage" } },
      { "n", "gx",            actions.open_file_external,          { desc = "Open the file with default system application" } },
      { "n", "<leader>e",     actions.focus_files,                 { desc = "Bring focus to the file panel" } },
      { "n", "<leader>b",     actions.toggle_files,                { desc = "Toggle the file panel" } },
      { "n", "g<C-x>",        actions.cycle_layout,                { desc = "Cycle available layouts" } },
      { "n", "g?",            actions.help("file_history_panel"),  { desc = "Open the help panel" } },
    },
    option_panel = {
      { "n", "<tab>", actions.select_entry,          { desc = "Change the current option" } },
      { "n", "q",     actions.close,                 { desc = "Close the panel" } },
      { "n", "g?",    actions.help("option_panel"),  { desc = "Open the help panel" } },
    },
    help_panel = {
      { "n", "q",     actions.close,  { desc = "Close help menu" } },
      { "n", "<esc>", actions.close,  { desc = "Close help menu" } },
    },
    commit_log_panel = {
      { "n", "q",     actions.close,  { desc = "Close commit log" } },
      { "n", "<esc>", actions.close,  { desc = "Close commit log" } },
    },
  },
}
-- stylua: ignore end

---@type EventEmitter
M.user_emitter = EventEmitter()
M._config = M.defaults

---@class GitLogOptions
---@field follow boolean
---@field first_parent boolean
---@field show_pulls boolean
---@field reflog boolean
---@field walk_reflogs boolean
---@field all boolean
---@field merges boolean
---@field no_merges boolean
---@field reverse boolean
---@field cherry_pick boolean
---@field left_only boolean
---@field right_only boolean
---@field max_count integer
---@field L string[]
---@field author string
---@field grep string
---@field G string
---@field S string
---@field diff_merges string
---@field rev_range string
---@field base string
---@field path_args string[]
---@field after string
---@field before string

---@class HgLogOptions
---@field follow string
---@field limit integer
---@field user string
---@field no_merges boolean
---@field rev string
---@field keyword string
---@field branch string
---@field bookmark string
---@field include string
---@field exclude string
---@field path_args string[]

---@alias LogOptions GitLogOptions|HgLogOptions

M.log_option_defaults = {
  ---@type GitLogOptions
  git = {
    follow = false,
    first_parent = false,
    show_pulls = false,
    reflog = false,
    walk_reflogs = false,
    all = false,
    merges = false,
    no_merges = false,
    reverse = false,
    cherry_pick = false,
    left_only = false,
    right_only = false,
    rev_range = nil,
    base = nil,
    max_count = 256,
    L = {},
    diff_merges = nil,
    author = nil,
    grep = nil,
    G = nil,
    S = nil,
    path_args = {},
  },
  ---@type HgLogOptions
  hg = {
    limit = 256,
    user = nil,
    no_merges = false,
    rev = nil,
    keyword = nil,
    include = nil,
    exclude = nil,
  },
}

---@return DiffviewConfig
function M.get_config()
  if not setup_done then
    M.setup()
  end

  return M._config
end

---@param single_file boolean
---@param t GitLogOptions|HgLogOptions
---@param vcs "git"|"hg"
---@return GitLogOptions|HgLogOptions
function M.get_log_options(single_file, t, vcs)
  local log_options

  if single_file then
    log_options =  M._config.file_history_panel.log_options[vcs].single_file
  else
    log_options = M._config.file_history_panel.log_options[vcs].multi_file
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

function M.find_option_keymap(t)
  for _, mapping in ipairs(t) do
    if mapping[3] and mapping[3] == actions.options then
      return mapping
    end
  end
end

function M.find_help_keymap(t)
  for _, mapping in ipairs(t) do
    if type(mapping[4]) == "table" and mapping[4].desc == "Open the help panel" then
      return mapping
    end
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

---@param ... table
---@return table
function M.extend_keymaps(...)
  local argc = select("#", ...)
  local argv = { ... }
  local contexts = {}

  for i = 1, argc do
    local cur = argv[i]
    if type(cur) == "table" then
      contexts[#contexts + 1] = { subject = cur, expanded = {} }
    end
  end

  for _, ctx in ipairs(contexts) do
    -- Expand the normal mode maps
    for lhs, rhs in pairs(ctx.subject) do
      if type(lhs) == "string" then
        ctx.expanded["n " .. lhs] = {
          "n",
          lhs,
          rhs,
          { silent = true, nowait = true },
        }
      end
    end

    for _, map in ipairs(ctx.subject) do
      for _, mode in ipairs(type(map[1]) == "table" and map[1] or { map[1] }) do
        ctx.expanded[mode .. " " .. map[2]] = utils.vec_join(
          mode,
          map[2],
          utils.vec_slice(map, 3)
        )
      end
    end
  end

  local merged = vim.tbl_extend("force", unpack(
    vim.tbl_map(function(v)
      return v.expanded
    end, contexts)
  ))

  return vim.tbl_values(merged)
end

function M.setup(user_config)
  user_config = user_config or {}

  M._config = vim.tbl_deep_extend(
    "force",
    utils.tbl_deep_clone(M.defaults),
    user_config
  )
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
    local top_options = {
      "single_file",
      "multi_file",
    }
    for _, name in ipairs(top_options) do
      if user_log_options[name] ~= nil then
        utils.warn("Global config of 'file_panel.log_options' has been deprecated. See ':h diffview.changelog-271'.")
      end
      break
    end

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
    local standard_layouts = { "diff1_plain", "diff2_horizontal", "diff2_vertical", -1 }
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
    for _, vcs in ipairs({ "git", "hg" }) do
      local t = M._config.file_history_panel.log_options[vcs]
      t[name] = vim.tbl_extend(
        "force",
        M.log_option_defaults[vcs],
        t[name]
      )
      for k, _ in pairs(t[name]) do
        if t[name][k] == "" then
          t[name][k] = nil
        end
      end
    end
  end

  for event, callback in pairs(M._config.hooks) do
    if type(callback) == "function" then
      M.user_emitter:on(event, function (_, ...)
        callback(...)
      end)
    end
  end

  if M._config.keymaps.disable_defaults then
    for name, _ in pairs(M._config.keymaps) do
      if name ~= "disable_defaults" then
        M._config.keymaps[name] = utils.tbl_access(user_config, { "keymaps", name }) or {}
      end
    end
  else
    M._config.keymaps = utils.tbl_clone(M.defaults.keymaps)
  end

  -- Merge default and user keymaps
  for name, keymap in pairs(M._config.keymaps) do
    if type(name) == "string" and type(keymap) == "table" then
      M._config.keymaps[name] = M.extend_keymaps(
        keymap,
        utils.tbl_access(user_config, { "keymaps", name }) or {}
      )
    end
  end

  -- Disable keymaps set to `false`
  for name, keymaps in pairs(M._config.keymaps) do
    if type(name) == "string" and type(keymaps) == "table" then
      for i = #keymaps, 1, -1 do
        local v = keymaps[i]
        if type(v) == "table" and not v[3] then
          table.remove(keymaps, i)
        end
      end
    end
  end

  setup_done = true
end

M.actions = actions
return M
