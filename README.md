# Diffview.nvim

Single tabpage interface for easily cycling through diffs for all modified files
for any git rev.

![preview](https://user-images.githubusercontent.com/2786478/131269942-e34100dd-cbb9-48fe-af31-6e518ce06e9e.png)


## Introduction

Vim's diff mode is pretty good, but there is no convenient way to quickly bring
up all modified files in a diffsplit. This plugin aims to provide a simple,
unified, single tabpage interface that lets you easily review all changed files
for any git rev.

## Requirements

- Git ≥ 2.31.0 (for Git support)
- Mercurial ≥ 5.4.0 (for Mercurial support)
- Neovim ≥ 0.10.0 (with LuaJIT)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-icons.md) (optional) for file icons

## Installation

Install the plugin with your package manager of choice.

```vim
" Plug
Plug 'sindrets/diffview.nvim'
```

```lua
-- Packer
use "sindrets/diffview.nvim" 
```

## Merge Tool

![merge tool showcase](https://user-images.githubusercontent.com/2786478/188286293-13bbf0ab-3595-425d-ba4a-12f514c17eb6.png)

Opening a diff view during a merge or a rebase will list the conflicted files in
their own section. When opening a conflicted file, it will open in a 3-way diff
allowing you to resolve the merge conflicts with the context of the target
branch's version, as well as the version from the branch which is being merged.

The 3-way diff is only the default layout for merge conflicts. There are
multiple variations on this layout, a 4-way diff layout, and a single window
layout available.

In addition to the normal `:h copy-diffs` mappings, there are default mappings
provided for jumping between conflict markers, obtaining a hunk directly from
any of the diff buffers, and accepting any one, all, or none of the versions of
a file given by a conflict region.

For more information on the merge tool, mappings, layouts and how to
configure them, see:

- `:h diffview-merge-tool`
- `:h diffview-config-view.x.layout`

## File History

![file history showcase](https://user-images.githubusercontent.com/2786478/188331057-f9ec9a0d-8cda-4ff8-ac98-febcc7aa4010.png)

The file history view allows you to list all the commits that affected a given
set of paths, and view the changes made in a diff split. This is a porcelain
interface for git-log, and supports a good number of its options. Things like:

- Filtering commits by grepping commit messages and commit authors.
- Tracing the line evolution of a given set of line ranges for multiple files.
- Only listing changes for a specific commit range, branch, or tag.
- Following file changes through renames.

Get started by opening file history for:

- The current branch: `:DiffviewFileHistory`
- The current file: `:DiffviewFileHistory %`

For more info, see `:h :DiffviewFileHistory`.

## Usage

### `:DiffviewOpen [git rev] [options] [ -- {paths...}]`

Calling `:DiffviewOpen` with no args opens a new Diffview that compares against
the current index. You can also provide any valid git rev to view only changes
for that rev.

Examples:

- `:DiffviewOpen`
- `:DiffviewOpen HEAD~2`
- `:DiffviewOpen HEAD~4..HEAD~2`
- `:DiffviewOpen d4a7b0d`
- `:DiffviewOpen d4a7b0d^!`
- `:DiffviewOpen d4a7b0d..519b30e`
- `:DiffviewOpen origin/main...HEAD`

You can also provide additional paths to narrow down what files are shown:

- `:DiffviewOpen HEAD~2 -- lua/diffview plugin`

For information about additional `[options]`, visit the
[documentation](https://github.com/sindrets/diffview.nvim/blob/main/doc/diffview.txt).

Additional commands for convenience:

- `:DiffviewClose`: Close the current diffview. You can also use `:tabclose`.
- `:DiffviewToggleFiles`: Toggle the file panel.
- `:DiffviewFocusFiles`: Bring focus to the file panel.
- `:DiffviewRefresh`: Update stats and entries in the file list of the current
  Diffview.

With a Diffview open and the default key bindings, you can cycle through changed
files with `<tab>` and `<s-tab>` (see configuration to change the key bindings).

#### Staging

You can stage individual hunks by editing any buffer that represents the index
(after running `:DiffviewOpen` with no `[git-rev]` the entries under "Changes"
will have the index buffer on the left side, and the entries under "Staged
changes" will have it on the right side). Once you write to an index buffer the
index will be updated.

### `:[range]DiffviewFileHistory [paths] [options]`

Opens a new file history view that lists all commits that affected the given
paths. This is a porcelain interface for git-log. Both `[paths]` and
`[options]` may be specified in any order, even interchangeably.

If no `[paths]` are given, defaults to the top-level of the working tree. The
top-level will be inferred from the current buffer when possible, otherwise the
cwd is used. Multiple `[paths]` may be provided and git pathspec is supported.

If `[range]` is given, the file history view will trace the line evolution of the
given range in the current file (for more info, see the `-L` flag in the docs).

Examples:

- `:DiffviewFileHistory`
- `:DiffviewFileHistory %`
- `:DiffviewFileHistory path/to/some/file.txt`
- `:DiffviewFileHistory path/to/some/directory`
- `:DiffviewFileHistory include/this and/this :!but/not/this`
- `:DiffviewFileHistory --range=origin..HEAD`
- `:DiffviewFileHistory --range=feat/example-branch`
- `:'<,'>DiffviewFileHistory`

> [!IMPORTANT]
> ### Familiarize Yourself With `:h diff-mode`
>
> This plugin assumes you're familiar with all the features already provided by
> nvim's builtin diff-mode. These features include:
>
> - Jumping between hunks (`:h jumpto-diffs`).
> - Applying the changes of a diff hunk from any of the diffed buffers
>   (`:h copy-diffs`).
> - And more...
>
> Read the help page for more info.

---

<br>

> [!NOTE]
> Additionally check out [USAGE](USAGE.md) for examples of some more specific
> use-cases.

<br>

---

## Configuration

<p>
<details>
<summary style='cursor: pointer'><b>Example config with default values</b></summary>

```lua
-- Lua
local actions = require("diffview.actions")

require("diffview").setup({
  diff_binaries = false,    -- Show diffs for binaries
  enhanced_diff_hl = false, -- See |diffview-config-enhanced_diff_hl|
  git_cmd = { "git" },      -- The git executable followed by default args.
  hg_cmd = { "hg" },        -- The hg executable followed by default args.
  use_icons = true,         -- Requires nvim-web-devicons
  show_help_hints = true,   -- Show hints for how to open the help panel
  watch_index = true,       -- Update views and index buffers when the git index changes.
  icons = {                 -- Only applies when use_icons is true.
    folder_closed = "",
    folder_open = "",
  },
  signs = {
    fold_closed = "",
    fold_open = "",
    done = "✓",
  },
  view = {
    -- Configure the layout and behavior of different types of views.
    -- Available layouts:
    --  'diff1_plain'
    --    |'diff2_horizontal'
    --    |'diff2_vertical'
    --    |'diff3_horizontal'
    --    |'diff3_vertical'
    --    |'diff3_mixed'
    --    |'diff4_mixed'
    -- For more info, see |diffview-config-view.x.layout|.
    default = {
      -- Config for changed files, and staged files in diff views.
      layout = "diff2_horizontal",
      disable_diagnostics = false,  -- Temporarily disable diagnostics for diff buffers while in the view.
      winbar_info = false,          -- See |diffview-config-view.x.winbar_info|
    },
    merge_tool = {
      -- Config for conflicted files in diff views during a merge or rebase.
      layout = "diff3_horizontal",
      disable_diagnostics = true,   -- Temporarily disable diagnostics for diff buffers while in the view.
      winbar_info = true,           -- See |diffview-config-view.x.winbar_info|
    },
    file_history = {
      -- Config for changed files in file history views.
      layout = "diff2_horizontal",
      disable_diagnostics = false,  -- Temporarily disable diagnostics for diff buffers while in the view.
      winbar_info = false,          -- See |diffview-config-view.x.winbar_info|
    },
  },
  file_panel = {
    listing_style = "tree",             -- One of 'list' or 'tree'
    tree_options = {                    -- Only applies when listing_style is 'tree'
      flatten_dirs = true,              -- Flatten dirs that only contain one single dir
      folder_statuses = "only_folded",  -- One of 'never', 'only_folded' or 'always'.
    },
    win_config = {                      -- See |diffview-config-win_config|
      position = "left",
      width = 35,
      win_opts = {},
    },
  },
  file_history_panel = {
    log_options = {   -- See |diffview-config-log_options|
      git = {
        single_file = {
          diff_merges = "combined",
        },
        multi_file = {
          diff_merges = "first-parent",
        },
      },
      hg = {
        single_file = {},
        multi_file = {},
      },
    },
    win_config = {    -- See |diffview-config-win_config|
      position = "bottom",
      height = 16,
      win_opts = {},
    },
  },
  commit_log_panel = {
    win_config = {},  -- See |diffview-config-win_config|
  },
  default_args = {    -- Default args prepended to the arg-list for the listed commands
    DiffviewOpen = {},
    DiffviewFileHistory = {},
  },
  hooks = {},         -- See |diffview-config-hooks|
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
      { "n", "<leader>e",   actions.focus_files,                    { desc = "Bring focus to the file panel" } },
      { "n", "<leader>b",   actions.toggle_files,                   { desc = "Toggle the file panel." } },
      { "n", "g<C-x>",      actions.cycle_layout,                   { desc = "Cycle through available layouts." } },
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
  },
})
```

</details>
</p>

### Hooks

The `hooks` table allows you to define callbacks for various events emitted from
Diffview. The available hooks are documented in detail in
`:h diffview-config-hooks`. The hook events are also available as User
autocommands. See `:h diffview-user-autocmds` for more details.

Examples:

```lua
hooks = {
  diff_buf_read = function(bufnr)
    -- Change local options in diff buffers
    vim.opt_local.wrap = false
    vim.opt_local.list = false
    vim.opt_local.colorcolumn = { 80 }
  end,
  view_opened = function(view)
    print(
      ("A new %s was opened on tab page %d!")
      :format(view.class:name(), view.tabpage)
    )
  end,
}
```

### Keymaps

The keymaps config is structured as a table with sub-tables for various
different contexts where mappings can be declared. In these sub-tables
key-value pairs are treated as the `{lhs}` and `{rhs}` of a normal mode
mapping. These mappings all use the `:map-arguments` `silent`, `nowait`, and
`noremap`. The implementation uses `vim.keymap.set()`, so the `{rhs}` can be
either a vim command in the form of a string, or it can be a lua function:

```lua
  view = {
    -- Vim command:
    ["a"] = "<Cmd>echom 'foo'<CR>",
    -- Lua function:
    ["b"] = function() print("bar") end,
  }
```

For more control (i.e. mappings for other modes), you can also define index
values as list-like tables containing the arguments for `vim.keymap.set()`.
This way you can also change all the `:map-arguments` with the only exception
being the `buffer` field, as this will be overridden with the target buffer
number:

```lua
view = {
  -- Normal and visual mode mapping to vim command:
  { { "n", "v" }, "<leader>a", "<Cmd>echom 'foo'<CR>", { silent = true } },
  -- Visual mode mapping to lua function:
  { "v", "<leader>b", function() print("bar") end, { nowait = true } },
}
```

To disable any single mapping without disabling them all, set its `{rhs}` to
`false`:

```lua
  view = {
    -- Disable the default normal mode mapping for `<tab>`:
    ["<tab>"] = false,
    -- Disable the default visual mode mapping for `gf`:
    { "x", "gf", false },
  }
```

Most of the mapped file panel actions also work from the view if they are added
to the view maps (and vice versa). The exception is for actions that only
really make sense specifically in the file panel, such as `next_entry`,
`prev_entry`. Actions such as `toggle_stage_entry` and `restore_entry` work
just fine from the view. When invoked from the view, these will target the file
currently open in the view rather than the file under the cursor in the file
panel.

**For more details on how to set mappings for other modes, actions, and more see:**
- `:h diffview-config-keymaps`
- `:h diffview-actions`

## Restoring Files

If the right side of the diff is showing the local state of a file, you can
restore the file to the state from the left side of the diff (key binding `X`
from the file panel by default). The current state of the file is stored in the
git object database, and a command is echoed that shows how to undo the change.

## Recommended Keymaps

These keymaps are commonly used patterns for working with diffview:

```lua
-- Toggle diffview open/close
vim.keymap.set('n', '<leader>dv', function()
  if next(require('diffview.lib').views) == nil then
    vim.cmd('DiffviewOpen')
  else
    vim.cmd('DiffviewClose')
  end
end, { desc = 'Toggle Diffview' })

-- Diff working directory
vim.keymap.set('n', '<leader>do', '<cmd>DiffviewOpen<cr>', { desc = 'Diffview open' })
vim.keymap.set('n', '<leader>dc', '<cmd>DiffviewClose<cr>', { desc = 'Diffview close' })

-- File history
vim.keymap.set('n', '<leader>dh', '<cmd>DiffviewFileHistory %<cr>', { desc = 'File history (current file)' })
vim.keymap.set('n', '<leader>dH', '<cmd>DiffviewFileHistory<cr>', { desc = 'File history (repo)' })

-- Visual mode: history for selection
vim.keymap.set('v', '<leader>dh', "<Esc><cmd>'<,'>DiffviewFileHistory --follow<CR>", { desc = 'Range history' })

-- Single line history
vim.keymap.set('n', '<leader>dl', '<cmd>.DiffviewFileHistory --follow<CR>', { desc = 'Line history' })

-- Diff against main/master branch (useful before merging)
vim.keymap.set('n', '<leader>dm', function()
  -- Try main first, fall back to master
  local handle = io.popen('git rev-parse --verify main 2>/dev/null')
  local result = handle:read('*a')
  handle:close()
  local branch = result ~= '' and 'main' or 'master'
  vim.cmd('DiffviewOpen ' .. branch)
end, { desc = 'Diff against main/master' })
```

## Tips and FAQ

- **Hide untracked files:**
  - `DiffviewOpen -uno`
- **Exclude certain paths:**
  - `DiffviewOpen -- :!exclude/this :!and/this`
- **Run as if git was started in a specific directory:**
  - `DiffviewOpen -C/foo/bar/baz`
- **Diff the index against a git rev:**
  - `DiffviewOpen HEAD~2 --cached`
  - Defaults to `HEAD` if no rev is given.
- **Q: How do I get the diagonal lines in place of deleted lines in
  diff-mode?**
  - A: Change your `:h 'fillchars'`:
    - (vimscript): `set fillchars+=diff:╱`
    - (Lua): `vim.opt.fillchars:append { diff = "╱" }`
  - Note: whether or not the diagonal lines will line up nicely will depend on
    your terminal emulator. The terminal used in the screenshots is Kitty.
- **Q: How do I jump between hunks in the diff?**
  - A: Use `[c` and `]c`
  - `:h jumpto-diffs`
- **Compare against merge-base (PR-style diff):**
  - `DiffviewOpen origin/main...HEAD --merge-base`
  - Shows only changes introduced since branching.
- **Use with [Neogit](https://github.com/NeogitOrg/neogit):**
  - Configure Neogit with `integrations = { diffview = true }` for seamless
    integration.
- **Trace line evolution:**
  - Visual select lines, then `:'<,'>DiffviewFileHistory --follow`
  - Or for single line: `:.DiffviewFileHistory --follow`
- **Better diff display (changes shown as add+delete instead of modification):**
  - Set Neovim's `diffopt` to use a better algorithm:
    - `vim.opt.diffopt:append { "algorithm:histogram" }`
  - Alternatives: `algorithm:patience` or `algorithm:minimal`
  - This affects how Neovim's built-in diff mode displays changes.
- **Understanding revision arguments:**
  - `DiffviewOpen HEAD~5` compares HEAD~5 to working tree (all changes since)
  - `DiffviewOpen HEAD~5..HEAD` compares HEAD~5 to HEAD (excludes working tree changes)
  - `DiffviewOpen HEAD~5^..HEAD~5` shows changes within that single commit
  - For viewing a specific commit's changes, use `DiffviewFileHistory` instead
- **LSP diagnostics in diff buffers:**
  - Diagnostics only appear for the working tree (LOCAL) side of diffs.
  - When comparing commits (e.g., `DiffviewOpen main..HEAD`), neither side is the
    working tree, so LSP won't attach to those buffers.
  - To see diagnostics, compare against the working tree: `DiffviewOpen main`
    (not `main..HEAD`). The right side will show your current files with
    diagnostics.
  - Inlay hints are automatically disabled for non-working-tree buffers to
    prevent position mismatch errors.
- **VSCode-style character-level highlighting:**
  - Pair diffview with
    [diffchar.vim](https://github.com/rickhowe/diffchar.vim) for precise
    character/word-level diff highlights. See
    [Companion Plugins > Recommended](#recommended) for setup details.
- **Customizing default keymaps to avoid conflicts:**
  - The default keymaps (`<leader>e`, `<leader>b`, `<leader>c*`) may conflict
    with your configuration. Override them in your setup:
    ```lua
    require("diffview").setup({
      keymaps = {
        view = {
          -- Use localleader instead to avoid conflicts
          { "n", "<localleader>e", actions.focus_files },
          { "n", "<localleader>b", actions.toggle_files },
          -- Or disable specific mappings
          { "n", "<leader>e", false },
        },
      },
    })
    ```

## Companion Plugins

### Recommended

- **[diffchar.vim](https://github.com/rickhowe/diffchar.vim) (VSCode-style character-level highlighting):**
  - diffchar.vim enhances diff mode with precise character and word-level
    highlighting. It automatically activates in diff mode, adding a second layer
    of highlights on top of Neovim's built-in line-level `DiffChange`
    backgrounds. This gives VSCode-style dual-layer highlighting: light
    backgrounds for changed lines plus fine-grained highlights for the exact
    characters that differ.
  - diffchar.vim works with diffview out of the box. Install the plugin and open
    a diff — no additional configuration is needed. You may want to enable
    visual indicators next to deleted characters to get VSCode-style
    character-level diffs, or disable diffchar's default keymaps (`<leader>g`,
    `<leader>p`) if they conflict with your mappings:
    ```lua
    {
      'rickhowe/diffchar.vim',
      config = function()
        -- Use bold/underline on adjacent chars instead of virtual blank columns.
        vim.g.DiffDelPosVisible = 1

        -- Disable diffchar default keymaps.
        -- See: https://github.com/rickhowe/diffchar.vim/issues/21
        vim.cmd([[
          nmap <Leader>g <Nop>
          nmap <Leader>p <Nop>
        ]])
      end,
    }
    ```
  - diffchar supports multiple diff granularities via `g:DiffUnit`: `'Char'`
    (character-level), `'Word1'` (words separated by non-word characters),
    `'Word2'` (whitespace-delimited words), and custom delimiter patterns. It
    also offers multi-colour matching via `g:DiffColors` to visually correlate
    corresponding changed units across windows.

- **[Telescope](https://github.com/nvim-telescope/telescope.nvim) integration:**
  - You can use Telescope to select branches or commits for diffview:
    ```lua
    -- Diff against a branch selected via Telescope
    vim.keymap.set('n', '<leader>db', function()
      require('telescope.builtin').git_branches({
        attach_mappings = function(_, map)
          map('i', '<CR>', function(prompt_bufnr)
            local selection = require('telescope.actions.state').get_selected_entry()
            require('telescope.actions').close(prompt_bufnr)
            vim.cmd('DiffviewOpen ' .. selection.value)
          end)
          return true
        end,
      })
    end, { desc = 'Diffview branch' })

    -- File history for a commit selected via Telescope
    vim.keymap.set('n', '<leader>dC', function()
      require('telescope.builtin').git_commits({
        attach_mappings = function(_, map)
          map('i', '<CR>', function(prompt_bufnr)
            local selection = require('telescope.actions.state').get_selected_entry()
            require('telescope.actions').close(prompt_bufnr)
            vim.cmd('DiffviewOpen ' .. selection.value .. '^!')
          end)
          return true
        end,
      })
    end, { desc = 'Diffview commit' })
    ```

### Known Issues

Some plugins may conflict with diffview's window layout or keymaps. Here are
known issues and workarounds:

- **lens.vim (automatic window resizing):**
  - [camspiers/lens.vim](https://github.com/camspiers/lens.vim) automatically
    resizes windows based on focus, which interferes with diffview's layout.
  - **Workaround:** Configure lens.vim to exclude diffview filetypes:
    ```lua
    -- In your lens.vim or lens.nvim config:
    vim.g['lens#disabled_filetypes'] = {
      'DiffviewFiles', 'DiffviewFileHistory', 'DiffviewFileHistoryPanel'
    }
    ```

- **[nvim-treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context):**
  - Context plugins that show code context at the top of windows can cause
    visual scrollbind misalignment.
  - **Workaround:** Configure the plugin to disable itself for diffview buffers
    using the `on_attach` callback:
    ```lua
    require('treesitter-context').setup({
      on_attach = function(buf)
        return not vim.b[buf].ts_context_disable
      end,
    })
    ```

- **[vim-markdown](https://github.com/preservim/vim-markdown) (preservim/vim-markdown):**
  - vim-markdown creates folds for markdown sections. Older versions of
    diffview set `foldlevel=0` which collapsed these sections, hiding diff
    content. This has been fixed by setting `foldlevel=99` by default.
  - If you still experience issues, you can manually set foldlevel in hooks:
    ```lua
    require('diffview').setup({
      hooks = {
        diff_buf_win_enter = function(bufnr, winid, ctx)
          if ctx.layout_name == 'diff2_horizontal' then
            vim.wo[winid].foldlevel = 99
          end
        end,
      },
    })
    ```

<!-- vim: set tw=80 -->
