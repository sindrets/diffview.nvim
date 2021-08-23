if !has('nvim-0.5') || exists('g:diffview_nvim_loaded') | finish | endif

command! -complete=customlist,s:completion -nargs=* DiffviewOpen lua require'diffview'.open(<f-args>)
command! -complete=file -nargs=* DiffviewFileHistory lua require'diffview'.file_history(<f-args>)
command! -nargs=0 DiffviewClose lua require'diffview'.close()
command! -nargs=0 DiffviewFocusFiles lua require'diffview'.trigger_event("focus_files")
command! -nargs=0 DiffviewToggleFiles lua require'diffview'.trigger_event("toggle_files")
command! -nargs=0 DiffviewRefresh lua require'diffview'.trigger_event("refresh_files")

function s:completion(argLead, cmdLine, curPos)
    return luaeval("require'diffview'.completion("
                \ . "vim.fn.eval('a:argLead'),"
                \ . "vim.fn.eval('a:cmdLine'),"
                \ . "vim.fn.eval('a:curPos'))")
endfunction

augroup Diffview
    au!
    au TabEnter * lua require'diffview'.trigger_event("tab_enter")
    au TabLeave * lua require'diffview'.trigger_event("tab_leave")
    au TabClosed * lua require'diffview'.close(tonumber(vim.fn.expand("<afile>")))
    au BufWritePost * lua require'diffview'.trigger_event("buf_write_post")
    au WinLeave * lua require'diffview'.trigger_event("win_leave")
    au User FugitiveChanged lua require'diffview'.trigger_event("refresh_files")
    au ColorScheme * lua require'diffview'.update_colors()
augroup END

let g:diffview_nvim_loaded = 1
