if exists('g:diffview_nvim_loaded') | finish | endif

if !luaeval("require('diffview.bootstrap')")
    finish
endif

command! -complete=customlist,s:completion -nargs=* DiffviewOpen lua require'diffview'.open(<f-args>)
command! -complete=customlist,s:completion -nargs=* DiffviewFileHistory lua require'diffview'.file_history(<f-args>)
command! -bar -nargs=0 DiffviewClose lua require'diffview'.close()
command! -bar -nargs=0 DiffviewFocusFiles lua require'diffview'.emit("focus_files")
command! -bar -nargs=0 DiffviewToggleFiles lua require'diffview'.emit("toggle_files")
command! -bar -nargs=0 DiffviewRefresh lua require'diffview'.emit("refresh_files")
command! -bar -nargs=0 DiffviewLog exe 'sp ' . fnameescape(v:lua.require('diffview.logger').outfile)

function s:completion(argLead, cmdLine, curPos)
    return luaeval("require'diffview'.completion("
                \ . "vim.fn.eval('a:argLead'),"
                \ . "vim.fn.eval('a:cmdLine'),"
                \ . "vim.fn.eval('a:curPos'))")
endfunction

augroup Diffview
    au!
    au TabEnter * lua require'diffview'.emit("tab_enter")
    au TabLeave * lua require'diffview'.emit("tab_leave")
    au TabClosed * lua require'diffview'.close(tonumber(vim.fn.expand("<afile>")))
    au BufWritePost * lua require'diffview'.emit("buf_write_post")
    au WinClosed * lua require'diffview'.emit("win_closed", tonumber(vim.fn.expand("<afile>")))
    au User FugitiveChanged lua require'diffview'.emit("refresh_files")
    au ColorScheme * lua require'diffview'.update_colors()
augroup END

let g:diffview_nvim_loaded = 1
