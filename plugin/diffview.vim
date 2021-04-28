if !has('nvim-0.5') || exists('g:diffview_nvim_loaded') | finish | endif

command! -nargs=* DiffviewOpen call s:diffview_open(<f-args>)

function s:diffview_open(...)
    lua require'diffview'.open(vim.fn.eval("a:000"))
endfunction

let g:diffview_nvim_loaded = 1
