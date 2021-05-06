if !has('nvim-0.5') || exists('g:diffview_nvim_loaded') | finish | endif

command! -complete=customlist,s:completion -nargs=* DiffviewOpen lua require'diffview'.open(<f-args>)
command! -nargs=0 DiffviewClose lua require'diffview'.close()
command! -nargs=0 DiffviewFocusFiles lua require'diffview'.on_keypress("focus_files")
command! -nargs=0 DiffviewToggleFiles lua require'diffview'.on_keypress("toggle_files")
command! -nargs=0 DiffviewRefresh lua require'diffview'.on_keypress("refresh_files")

function s:diffview_open(...)
    lua require'diffview'.open(vim.fn.eval("a:000"))
endfunction

function s:completion(argLead, cmdLine, curPos)
    return luaeval("require'diffview'.completion("
                \ . "vim.fn.eval('a:argLead'),"
                \ . "vim.fn.eval('a:cmdLine'),"
                \ . "vim.fn.eval('a:curPos'))")
endfunction

augroup Diffview
    au!
    au TabEnter * lua require'diffview'.on_tab_enter()
    au TabLeave * lua require'diffview'.on_tab_leave()
    au TabClosed * lua require'diffview'.close(tonumber(vim.fn.expand("<afile>")))
    au BufWritePost * lua require'diffview'.on_buf_write_post()
    au WinLeave * lua require'diffview'.on_win_leave()
    au User FugitiveChanged lua require'diffview'.on_keypress("refresh_files")
    au ColorScheme * lua require'diffview'.update_colors()
augroup END

let g:diffview_nvim_loaded = 1
