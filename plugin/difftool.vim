if !has('nvim-0.5') || exists('g:difftool_nvim_loaded') | finish | endif

command! -nargs=* Difftool call DifftoolRun(<f-args>)

function DifftoolRun(...)
    lua require'difftool'.run(vim.fn.eval("a:000"))
endfunction

let g:difftool_nvim_loaded = 1
