# Usage

This document contains a few guides for solving common problems, and describes
some more specific use-cases.

## Review a PR

### Comparing All the Changes

First, checkout the branch locally. If it's a GitHub PR, you can use
[`gh`](https://github.com/cli/cli) to do this:

```console
$ gh pr checkout {PR_ID}
```

Now, run a symmetric diff against the base branch:

```vim
:DiffviewOpen origin/main...HEAD --imply-local
```

The symmetric difference rev range (triple dot) will here compare the changes on
the current branch (the PR branch) against its merge-base in `origin/main`. This
is different than comparing directly against `origin/main` if the branches have
diverged, and is usually what you want when comparing changes in a PR. For more
info see the section on "SPECIFYING REVISIONS" in `man git-rev-parse(1)`.

The `--imply-local` flag option will here make diffview.nvim show the working
tree versions[^1] of the changed files on the right side of the diff. This means
that if you have tools such as LSP set up, it will work for all the diff buffers
on the right side, giving you access to LSP features - such as diagnostics and
references - that can be useful while reviewing changes.

If you want the plugin to always use this option, you can add it to your default
args:

```lua
default_args = {
  DiffviewOpen = { "--imply-local" },
}
```

From the file panel you can press `L` to open the commit log for all the
changes. This lets you check the full commit messages for all the commits
involved.

![diffview symdiff demo](https://user-images.githubusercontent.com/2786478/229858634-c751ebe3-cc43-48de-adda-bf0b71fa2ce7.png)

[^1]: The files as they currently exist on disk.

### Comparing Changes From the Individual PR Commits

If you're reviewing a big PR composed of many commits, you might prefer to
review the changes introduced in each of those commits individually. To do
this, you can use `:DiffviewFileHistory`:

```vim
:DiffviewFileHistory --range=origin/main...HEAD --right-only --no-merges
```

Here we are again using a symmetric difference range. However, symdiff ranges
have different behavior between `git-diff` and `git-log`. Whereas in `git-diff`
it compares against the merge-base, here it will select only the commits that
are reachable from *either* `origin/main` *or* `HEAD`, but not from both (in
other words, it's actually performing a symmetric difference here).

We then use the cherry-pick option `--right-only` to limit the commits to only
those on the right side of the symmetric difference. Finally `--no-merges`
filters out merge commits. We are left with a list of all the non-merge commits
from the PR branch.

![file history cherry pick demo](https://user-images.githubusercontent.com/2786478/229853402-f45280ee-f6e2-4325-8a39-ce25b9c5221e.png)

## Committing

Creating commits from within nvim is a solved problem, and as such diffview.nvim
does not reinvent the wheel here. Here are a few different ways in which you can
create a new commit from within the editor:

### Use a Git Wrapper Plugin (Recommended)

Diffview.nvim *is not*, and *does not try to be* a complete git wrapper. As
such, there are a number of features offered by such plugins that won't ever be
implemented here, because they are deemed out-of-scope. It's therefore
recommended to use some form of a Git wrapper plugin in order to get a more
complete integration of Git's features into your editor. Here are a few options:

- [`vim-fugitive`](https://github.com/tpope/vim-fugitive)
- [`neogit`](https://github.com/TimUntersberger/neogit)
- [`lazygit.nvim`](https://github.com/kdheepak/lazygit.nvim)

Example creating some `vim-fugitive` mappings for committing staged changes
from the file panel:

```lua
keymaps = {
  file_panel = {
    {
      "n", "cc",
      "<Cmd>Git commit <bar> wincmd J<CR>",
      { desc = "Commit staged changes" },
    },
    {
      "n", "ca",
      "<Cmd>Git commit --amend <bar> wincmd J<CR>",
      { desc = "Amend the last commit" },
    },
    {
      "n", "c<space>",
      ":Git commit ",
      { desc = "Populate command line with \":Git commit \"" },
    },
  },
}
```

### Use [`neovim-remote`](https://github.com/mhinz/neovim-remote)

`neovim-remote` is a more complete version of the builtin `:h clientserver`.
Notably it implements all the `:h clientserver-missing` functionality. Hopefully
this functionality will be implemented in core at some point in the future. But
until then this separate application is needed to get the `--{...}-wait`
variants of the remote options.

With the remote installed you can simply configure your `$GIT_EDITOR`
environment variable from within the editor such that when the Git editor is
invoked, it will open in a new split inside the current editor session. This
avoids the problem of spawning nested nvim instances every time an `$EDITOR` is
invoked. Put this somewhere in your `init.lua`:

```lua
if vim.fn.executable("nvr") == 1 then
  local nvr = "nvr --servername " .. vim.v.servername .. " "
  vim.env.GIT_EDITOR = nvr .. "-cc split +'setl bh=delete' --remote-wait"
  vim.env.EDITOR = nvr .. "-l --remote" -- (Optional)
  vim.env.VISUAL = nvr .. "-l --remote" -- (Optional)
end
```

Example creating some mappings for committing staged changes from the file
panel, that will trigger `nvr`:

```lua
keymaps = {
  file_panel = {
    {
      "n", "cc",
      [[<Cmd>call jobstart(["git", "commit"]) | au BufWinEnter * ++once wincmd J<CR>]],
      { desc = "Commit staged changes" },
    },
    {
      "n", "ca",
      [[<Cmd>call jobstart(["git", "commit", "--amend"]) | au BufWinEnter * ++once wincmd J<CR>]],
      { desc = "Amend the last commit" },
    },
  },
}
```

### Use `:terminal`

The `:h :terminal` command allows you to run interactive terminal jobs. However,
unlike the [previously discussed](#use-neovim-remote) `neovim-remote` solution
this will spawn nested instances of nvim.

Example creating some `:terminal` mappings for committing staged changes from
the file panel:

```lua
keymaps = {
  file_panel = {
    {
      "n", "cc",
      "<Cmd>sp <bar> wincmd J <bar> term git commit<CR>",
      { desc = "Commit staged changes" },
    },
    {
      "n", "ca",
      "<Cmd>sp <bar> wincmd J <bar> term git commit -amend<CR>",
      { desc = "Amend the last commit" },
    },
  },
}
```

### Use `:!cmd`

If you only ever write simple commit messages you could make use of `:h !cmd`:

```vim
:!git commit -m 'some commit message'
```

<!-- vim: set tw=80 -->
