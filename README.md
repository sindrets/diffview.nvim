# Diffview.nvim

> **Note:** This is an **actively maintained fork** of [sindrets/diffview.nvim](https://github.com/sindrets/diffview.nvim) with bug fixes and improvements applied. The original repository has not been updated since June 2024.

## Introduction

Single tabpage interface for easily cycling through diffs for all modified files
for any git rev. Review all changed files, resolve merge conflicts, and browse
file history from a unified view.

![preview](https://user-images.githubusercontent.com/2786478/131269942-e34100dd-cbb9-48fe-af31-6e518ce06e9e.png)

## Requirements

- Neovim ≥ 0.10.0 (with LuaJIT)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-icons.md) (optional) for file icons

Supported VCS (at least one required):

- **Git** ≥ 2.31.0
- **Mercurial** ≥ 5.4.0
- **Sapling** (any version; detected automatically via the Mercurial adapter)
- **Jujutsu** ≥ 0.38.0 (`:DiffviewOpen` only; file history is not yet supported)
- **Perforce** ≥ 2019.1 with the `p4` CLI (experimental)

## Installation

```lua
-- Lazy
{
    "dlyongemallo/diffview.nvim",
    version = "*",
}
```

```vim
" Plug
Plug 'dlyongemallo/diffview.nvim'
```

## Quick Start

```vim
:DiffviewOpen              " Diff working tree against index
:DiffviewFileHistory %     " History for the current file
:DiffviewFileHistory       " History for the whole repo
:DiffviewClose             " Close the current diffview
```

Press `g?` in any diffview buffer to see all available keymaps.

See [USAGE.md](USAGE.md) for detailed guides on PR review, stash inspection,
and committing workflows.

## Features

- **Diff View** — Browse all changed files in a single tabpage. Stage
  individual hunks by editing index buffers directly.
  ![preview](https://user-images.githubusercontent.com/2786478/131269942-e34100dd-cbb9-48fe-af31-6e518ce06e9e.png)

- **File History** — List all commits affecting a file, directory, or line
  range. Filter by author, message, date range, and more.
  ![file history](https://user-images.githubusercontent.com/2786478/188331057-f9ec9a0d-8cda-4ff8-ac98-febcc7aa4010.png)

- **Merge Tool** — 3-way and 4-way diff layouts for resolving conflicts,
  with mappings for choosing OURS/THEIRS/BASE versions.
  ![merge tool](https://user-images.githubusercontent.com/2786478/188286293-13bbf0ab-3595-425d-ba4a-12f514c17eb6.png)

- **Staging** — Stage and unstage individual files or all changes from the
  file panel (`-` / `s` / `S` / `U`).

## Commands

| Command | Description |
|---|---|
| `:DiffviewOpen [rev] [options] [ -- {paths...}]` | Open a diff view |
| `:DiffviewFileHistory [paths] [options]` | Browse file/commit history |
| `:DiffviewClose` | Close the current diffview |
| `:DiffviewToggleFiles` | Toggle the file panel |
| `:DiffviewFocusFiles` | Bring focus to the file panel |
| `:DiffviewRefresh` | Update stats and entries in the file list |

Examples:

```vim
:DiffviewOpen                      " Working tree changes
:DiffviewOpen HEAD~2               " Changes since HEAD~2
:DiffviewOpen origin/main...HEAD   " Symmetric diff (PR-style)
:DiffviewOpen -- lua/diffview      " Limit to specific paths
:DiffviewFileHistory %             " Current file history
:'<,'>DiffviewFileHistory          " History for selected lines
```

#### VCS Adapter Notes

- **Jujutsu** currently supports only `:DiffviewOpen`. The options `--cached`,
  `--staged`, and `--imply-local` are Git-only. In colocated repos, set
  `preferred_adapter = "jj"` to use the Jujutsu adapter.
- **Sapling** is detected automatically through the Mercurial adapter. Use
  `hg_cmd` to configure the executable (e.g. `hg_cmd = { "sl" }`).
- **Perforce** support is experimental. Requires the `p4` CLI ≥ 2019.1
  and the environment variables `P4PORT`, `P4USER`, `P4CLIENT`.

For full command documentation, see `:h diffview-commands`.

> [!IMPORTANT]
> ### Familiarize Yourself With `:h diff-mode`
>
> This plugin builds on nvim's built-in diff mode. Make sure you're familiar
> with jumping between hunks (`:h jumpto-diffs`) and applying diff changes
> (`:h copy-diffs`).

## Configuration

A minimal configuration showing commonly customised options:

```lua
require("diffview").setup({
  enhanced_diff_hl = true,
  use_icons = true,
  view = {
    default = { layout = "diff2_horizontal" },
    merge_tool = { layout = "diff3_horizontal" },
  },
  file_panel = {
    listing_style = "tree",
    win_config = { position = "left", width = 35 },
  },
  hooks = {},   -- See :h diffview-config-hooks
  keymaps = {}, -- See :h diffview-config-keymaps
})
```

For the full list of options with defaults, see
[`doc/diffview_defaults.txt`](doc/diffview_defaults.txt) or run
`:h diffview.defaults` in Neovim.

See [RECIPES.md](RECIPES.md) for ready-to-use configuration snippets covering
PR review, merge conflicts, file history, and more.

## Companion Plugins

- **[diffchar.vim](https://github.com/rickhowe/diffchar.vim)** — VSCode-style
  character/word-level diff highlighting. Works out of the box.
- **[Telescope](https://github.com/nvim-telescope/telescope.nvim)** — Select
  branches or commits interactively. See [RECIPES.md](RECIPES.md) for setup.
- **[Neogit](https://github.com/NeogitOrg/neogit)** — Git porcelain with
  built-in diffview integration (`integrations = { diffview = true }`).

See [TIPS.md](TIPS.md) for setup details and known compatibility issues.

## Tips and FAQ

See [TIPS.md](TIPS.md) for common usage patterns, revision argument
guide, LSP diagnostics in diffs, platform notes, and plugin compatibility.

## Further Reading

| Resource | Description |
|---|---|
| [USAGE.md](USAGE.md) | PR review, stash inspection, committing guides |
| [RECIPES.md](RECIPES.md) | Configuration snippets and recommended keymaps |
| [TIPS.md](TIPS.md) | Tips, FAQ, and known compatibility issues |
| `:h diffview` | Full plugin documentation |
| `:h diffview.defaults` | Complete default configuration |


<!-- vim: set tw=80 -->
