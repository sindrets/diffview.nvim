local _MODREV, _SPECREV = 'scm', '-1'
rockspec_format = "3.0"
package = 'diffview.nvim'
version = _MODREV .. _SPECREV

description = {
   summary = 'Single tabpage interface for easily cycling through diffs for all modified files for any git rev.',
   labels = { 'neovim', 'neovim-plugin', 'git', 'diff', 'neovim-lua', 'neovim-lua-plugin', },
   detailed = [[
     Vim's diff mode is pretty good, but there is no convenient way to quickly bring up all modified files in a diffsplit.
     This plugin aims to provide a simple, unified, single tabpage interface that lets you easily review all changed files for any git rev.
   ]],
   homepage = 'https://github.com/sindrets/diffview.nvim',
   license = 'GPL-3.0',
}

dependencies = {
   'lua >= 5.1, < 5.4',
   'nvim-web-devicons',
}

source = {
   url = 'git://github.com/sindrets/diffview.nvim',
}

build = {
   type = 'builtin',
   copy_directories = {
     'doc',
     'plugin',
   },
}
