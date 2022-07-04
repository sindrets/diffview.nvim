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

- Git ≥ 2.31.0
- Neovim ≥ 0.7.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nvim-web-devicons](https://github.com/kyazdani42/nvim-web-devicons) (optional) For file icons

## Installation

Install the plugin with your package manager of choice.

```vim
" Plug
Plug 'nvim-lua/plenary.nvim'
Plug 'sindrets/diffview.nvim'
```

```lua
-- Packer
use { 'sindrets/diffview.nvim', requires = 'nvim-lua/plenary.nvim' }
```

## Configuration

<p>
<details>
<summary style='cursor: pointer'><b>Example config with default values</b></summary>

```lua
-- Lua
local actions = require("diffview.actions")

require("diffview").setup({
  diff_binaries = false,    -- Show diffs for binaries
  enhanced_diff_hl = false, -- See ':h diffview-config-enhanced_diff_hl'
  git_cmd = { "git" },      -- The git executable followed by default args.
  use_icons = true,         -- Requires nvim-web-devicons
  icons = {                 -- Only applies when use_icons is true.
    folder_closed = "",
    folder_open = "",
  },
  signs = {
    fold_closed = "",
    fold_open = "",
  },
  file_panel = {
    listing_style = "tree",             -- One of 'list' or 'tree'
    tree_options = {                    -- Only applies when listing_style is 'tree'
      flatten_dirs = true,              -- Flatten dirs that only contain one single dir
      folder_statuses = "only_folded",  -- One of 'never', 'only_folded' or 'always'.
    },
    win_config = {                      -- See ':h diffview-config-win_config'
      position = "left",
      width = 35,
    },
  },
  file_history_panel = {
    log_options = {   -- See ':h diffview-config-log_options'
      single_file = {
        diff_merges = "combined",
      },
      multi_file = {
        diff_merges = "first-parent",
      },
    },
    win_config = {    -- See ':h diffview-config-win_config'
      position = "bottom",
      height = 16,
    },
  },
  commit_log_panel = {
    win_config = {},  -- See ':h diffview-config-win_config'
  },
  default_args = {    -- Default args prepended to the arg-list for the listed commands
    DiffviewOpen = {},
    DiffviewFileHistory = {},
  },
  hooks = {},         -- See ':h diffview-config-hooks'
  keymaps = {
    disable_defaults = false, -- Disable the default keymaps
    view = {
      -- The `view` bindings are active in the diff buffers, only when the current
      -- tabpage is a Diffview.
      ["<tab>"]      = actions.select_next_entry, -- Open the diff for the next file
      ["<s-tab>"]    = actions.select_prev_entry, -- Open the diff for the previous file
      ["gf"]         = actions.goto_file,         -- Open the file in a new split in the previous tabpage
      ["<C-w><C-f>"] = actions.goto_file_split,   -- Open the file in a new split
      ["<C-w>gf"]    = actions.goto_file_tab,     -- Open the file in a new tabpage
      ["<leader>e"]  = actions.focus_files,       -- Bring focus to the files panel
      ["<leader>b"]  = actions.toggle_files,      -- Toggle the files panel.
    },
    file_panel = {
      ["j"]             = actions.next_entry,         -- Bring the cursor to the next file entry
      ["<down>"]        = actions.next_entry,
      ["k"]             = actions.prev_entry,         -- Bring the cursor to the previous file entry.
      ["<up>"]          = actions.prev_entry,
      ["<cr>"]          = actions.select_entry,       -- Open the diff for the selected entry.
      ["o"]             = actions.select_entry,
      ["<2-LeftMouse>"] = actions.select_entry,
      ["-"]             = actions.toggle_stage_entry, -- Stage / unstage the selected entry.
      ["S"]             = actions.stage_all,          -- Stage all entries.
      ["U"]             = actions.unstage_all,        -- Unstage all entries.
      ["X"]             = actions.restore_entry,      -- Restore entry to the state on the left side.
      ["R"]             = actions.refresh_files,      -- Update stats and entries in the file list.
      ["L"]             = actions.open_commit_log,    -- Open the commit log panel.
      ["<c-b>"]         = actions.scroll_view(-0.25), -- Scroll the view up
      ["<c-f>"]         = actions.scroll_view(0.25),  -- Scroll the view down
      ["<tab>"]         = actions.select_next_entry,
      ["<s-tab>"]       = actions.select_prev_entry,
      ["gf"]            = actions.goto_file,
      ["<C-w><C-f>"]    = actions.goto_file_split,
      ["<C-w>gf"]       = actions.goto_file_tab,
      ["i"]             = actions.listing_style,        -- Toggle between 'list' and 'tree' views
      ["f"]             = actions.toggle_flatten_dirs,  -- Flatten empty subdirectories in tree listing style.
      ["<leader>e"]     = actions.focus_files,
      ["<leader>b"]     = actions.toggle_files,
    },
    file_history_panel = {
      ["g!"]            = actions.options,          -- Open the option panel
      ["<C-A-d>"]       = actions.open_in_diffview, -- Open the entry under the cursor in a diffview
      ["y"]             = actions.copy_hash,        -- Copy the commit hash of the entry under the cursor
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
})
```

</details>
</p>

### Layout

The diff windows can be aligned either with a horizontal split or a vertical
split. To change the alignment add either `horizontal` or `vertical` to your
`'diffopt'`.

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
      :format(view:class():name(), view.tabpage)
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

To disable any single mapping without disabling them all, set its value to
`false`:

```lua
  view = {
    -- Disable the default mapping for <tab>:
    ["<tab>"] = false,
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

## File History

![file-history-multi](https://user-images.githubusercontent.com/2786478/131269782-f4184640-6d73-4226-b425-feccb5002dd0.png)

The file history view allows you to list all the commits that affected a given
file or directory, and view the changes made in a diff split. This is a
porcelain interface for git-log. Open a file history view for your current file
by calling `:DiffviewFileHistory %`.

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
- `:DiffviewOpen d4a7b0d..519b30e`
- `:DiffviewOpen origin/main...HEAD`

You can also provide additional paths to narrow down what files are shown:

- `:DiffviewOpen HEAD~2 -- lua/diffview plugin`

For information about additional `[options]`, visit the
[documentation](https://github.com/sindrets/diffview.nvim/blob/main/doc/diffview.txt).

Additional commands for convenience:

- `:DiffviewClose`: Close the current diffview. You can also use `:tabclose`.
- `:DiffviewToggleFiles`: Toggle the files panel.
- `:DiffviewFocusFiles`: Bring focus to the files panel.
- `:DiffviewRefresh`: Update stats and entries in the file list of the current
  Diffview.

With a Diffview open and the default key bindings, you can cycle through changed
files with `<tab>` and `<s-tab>` (see configuration to change the key bindings).

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

## Restoring Files

If the right side of the diff is showing the local state of a file, you can
restore the file to the state from the left side of the diff (key binding `X`
from the file panel by default). The current state of the file is stored in the
git object database, and a command is echoed that shows how to undo the change.

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
  - Note: whether or not the diagonal lines will line up nicely will depend on
    your terminal emulator. The terminal used in the screenshots is Kitty.
