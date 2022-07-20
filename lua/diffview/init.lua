if not require("diffview.bootstrap") then
  return
end

local colors = require("diffview.colors")
local lazy = require("diffview.lazy")

---@module "diffview.arg_parser"
local arg_parser = lazy.require("diffview.arg_parser")
---@module "diffview.config"
local config = lazy.require("diffview.config")
---@module "diffview.git.utils"
local git = lazy.require("diffview.git.utils")
---@module "diffview.lib"
local lib = lazy.require("diffview.lib")
---@module "diffview.logger"
local logger = lazy.require("diffview.logger")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local api = vim.api

local M = {}

---@type FlagValueMap
local comp_open = arg_parser.FlagValueMap()
comp_open:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
comp_open:put({ "cached", "staged" })
comp_open:put({ "imply-local" })
comp_open:put({ "C" }, function(_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "dir")
end)
comp_open:put({ "selected-file" }, function (_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "file")
end)

---@type FlagValueMap
local comp_file_history = arg_parser.FlagValueMap()
comp_file_history:put({ "base" }, function(_, arg_lead)
  return utils.vec_join("LOCAL", M.rev_completion(arg_lead))
end)
comp_file_history:put({ "range" }, function(_, arg_lead)
  return M.rev_completion(arg_lead, { accept_range = true })
end)
comp_file_history:put({ "C" }, function(_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "dir")
end)
comp_file_history:put({ "--follow" })
comp_file_history:put({ "--first-parent" })
comp_file_history:put({ "--show-pulls" })
comp_file_history:put({ "--reflog" })
comp_file_history:put({ "--all" })
comp_file_history:put({ "--merges" })
comp_file_history:put({ "--no-merges" })
comp_file_history:put({ "--reverse" })
comp_file_history:put({ "--max-count", "-n" }, {})
comp_file_history:put({ "-L" }, function (_, arg_lead)
  return M.line_trace_completion(arg_lead)
end)
comp_file_history:put({ "--diff-merges" }, {
  "off",
  "on",
  "first-parent",
  "separate",
  "combined",
  "dense-combined",
  "remerge",
})
comp_file_history:put({ "--author" }, {})
comp_file_history:put({ "--grep" }, {})

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  local au = api.nvim_create_autocmd
  colors.setup()

  -- Set up autocommands
  M.augroup = api.nvim_create_augroup("diffview_nvim", {})
  au("TabEnter", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("tab_enter")
    end,
  })
  au("TabLeave", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("tab_leave")
    end,
  })
  au("TabClosed", {
    group = M.augroup,
    pattern = "*",
    callback = function(state)
      M.close(tonumber(state.file))
    end,
  })
  au("BufWritePost", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("buf_write_post")
    end,
  })
  au("WinClosed", {
    group = M.augroup,
    pattern = "*",
    callback = function(state)
      M.emit("win_closed", tonumber(state.file))
    end,
  })
  au("ColorScheme", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.update_colors()
    end,
  })
  au("User", {
    group = M.augroup,
    pattern = "FugitiveChanged",
    callback = function(_)
      M.emit("refresh_files")
    end,
  })

  -- Set up user autocommand emitters
  DiffviewGlobal.emitter:on("view_opened", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewOpened")
  end)
  DiffviewGlobal.emitter:on("view_closed", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewClosed")
  end)
  DiffviewGlobal.emitter:on("view_enter", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewEnter")
  end)
  DiffviewGlobal.emitter:on("view_leave", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewLeave")
  end)
  DiffviewGlobal.emitter:on("diff_buf_read", function(_)
    vim.cmd("do <nomodeline> User DiffviewDiffBufRead")
  end)
  DiffviewGlobal.emitter:on("diff_buf_win_enter", function(_)
    vim.cmd("do <nomodeline> User DiffviewDiffBufWinEnter")
  end)

  -- Set up completion wrapper used by `vim.ui.input()`
  vim.cmd([[
    function! Diffview__ui_input_completion(...) abort
      return luaeval("DiffviewGlobal.state.current_completer(
            \ unpack(vim.fn.eval('a:000')))")
    endfunction
  ]])
end

function M.open(...)
  local view = lib.diffview_open(utils.tbl_pack(...))
  if view then
    view:open()
  end
end

---@param range? { [1]: integer, [2]: integer }
function M.file_history(range, ...)
  local view = lib.file_history(range, utils.tbl_pack(...))
  if view then
    view:open()
  end
end

function M.close(tabpage)
  if tabpage then
    vim.schedule(function()
      lib.dispose_stray_views()
    end)
    return
  end

  local view = lib.get_current_view()
  if view then
    view:close()
    lib.dispose_view(view)
  end
end

---@param arg_lead string
---@param items string[]
---@return string[]
function M.filter_completion(arg_lead, items)
  arg_lead, _ = vim.pesc(arg_lead)
  return vim.tbl_filter(function(item)
    return item:match(arg_lead)
  end, items)
end

function M.completion(arg_lead, cmd_line, cur_pos)
  local args, argidx, divideridx = arg_parser.scan_ex_args(cmd_line, cur_pos)
  local _, cmd = arg_parser.split_ex_range(args[1])

  if cmd == "" then
    cmd = args[2]
  end

  if cmd and M.completers[cmd] then
    return M.filter_completion(arg_lead, M.completers[cmd](args, argidx, divideridx, arg_lead))
  end
end

function M.rev_candidates(git_root, git_dir)
  logger.lvl(1).debug("[completion] Revision candidates requested.")
  local top_indicators
  if not (git_root and git_dir) then
    local cfile = utils.path:vim_expand("%")
    top_indicators = utils.vec_join(
      vim.bo.buftype == ""
          and utils.path:absolute(cfile)
          or nil,
      utils.path:realpath(".")
    )
  end

  if not (git_root and git_dir) then
    local err
    err, git_root = lib.find_git_toplevel(top_indicators)

    if err then
      return {}
    end

    git_dir = git.git_dir(git_root)
  end

  if not (git_root and git_dir) then
    return {}
  end

  -- stylua: ignore start
  local targets = {
    "HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
    "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"
  }
  -- stylua: ignore end

  local heads = vim.tbl_filter(
    function(name) return vim.tbl_contains(targets, name) end,
    vim.tbl_map(
      function(v) return utils.path:basename(v) end,
      vim.fn.glob(git_dir .. "/*", false, true)
    )
  )
  local revs = git.exec_sync(
    { "rev-parse", "--symbolic", "--branches", "--tags", "--remotes" },
    { cwd = git_root, silent = true }
  )
  local stashes = git.exec_sync(
    { "stash", "list", "--pretty=format:%gd" },
    { cwd = git_root, silent = true }
  )

  return utils.vec_join(heads, revs, stashes)
end

---@class RevCompletionSpec
---@field accept_range boolean
---@field git_root string
---@field git_dir string

---Completion for git revisions.
---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function M.rev_completion(arg_lead, opt)
  ---@type RevCompletionSpec
  opt = vim.tbl_extend("keep", opt or {}, { accept_range = false })
  local candidates = M.rev_candidates(opt.git_root, opt.git_dir)
  local _, range_end = utils.str_match(arg_lead, {
    "^(%.%.%.?)()$",
    "^(%.%.%.?)()[^.]",
    "[^.](%.%.%.?)()$",
    "[^.](%.%.%.?)()[^.]",
  })

  if opt.accept_range and range_end then
    local range_lead = arg_lead:sub(1, range_end - 1)
    candidates = vim.tbl_map(function(v)
      return range_lead .. v
    end, candidates)
  end

  return M.filter_completion(arg_lead, candidates)
end

---Completion for the git-log `-L` flag.
---@param arg_lead string
---@return string[]
function M.line_trace_completion(arg_lead)
  local range_end = arg_lead:match(".*:()")

  if not range_end then
    return
  else
    local lead = arg_lead:sub(1, range_end - 1)
    local path_lead = arg_lead:sub(range_end)

    return vim.tbl_map(function(v)
      return lead .. v
    end, vim.fn.getcompletion(path_lead, "file"))
  end
end

M.completers = {
  DiffviewOpen = function(args, argidx, divideridx, arg_lead)
    local cfile = utils.path:vim_expand("%")
    local top_indicators = utils.vec_join(
      vim.bo.buftype == ""
          and utils.path:absolute(cfile)
          or nil,
      utils.path:realpath(".")
    )

    local has_rev_arg = false
    local git_dir
    local err, git_root = lib.find_git_toplevel(top_indicators)

    if not err then
      git_dir = git.git_dir(git_root)
    end

    for i = 2, math.min(#args, divideridx) do
      if args[i]:sub(1, 1) ~= "-" and i ~= argidx then
        has_rev_arg = true
        break
      end
    end

    local candidates = {}

    if argidx > divideridx then
      utils.vec_push(candidates, unpack(vim.fn.getcompletion(arg_lead, "file", 0)))
    elseif not has_rev_arg and arg_lead:sub(1, 1) ~= "-" and git_dir and git_root then
      utils.vec_push(candidates, unpack(comp_open:get_all_names()))
      utils.vec_push(candidates, unpack(M.rev_completion(arg_lead, {
        accept_range= true,
        git_root = git_root,
        git_dir = git_dir,
      })))
    else
      utils.vec_push(candidates, unpack(
        comp_open:get_completion(arg_lead)
        or comp_open:get_all_names()
      ))
    end

    return candidates
  end,
  ---@diagnostic disable-next-line: unused-local
  DiffviewFileHistory = function(args, argidx, divideridx, arg_lead)
    local candidates = {}

    utils.vec_push(candidates, unpack(
      comp_file_history:get_completion(arg_lead)
      or comp_file_history:get_all_names()
    ))

    utils.vec_push(candidates, unpack(vim.fn.getcompletion(arg_lead, "file", 0)))

    return candidates
  end,
}

function M.update_colors()
  colors.setup()
  lib.update_colors()
end

local function _emit(no_recursion, event_name, ...)
  local view = lib.get_current_view()

  if view and not view.closing then
    local that = view.emitter
    local fn = no_recursion and that.nore_emit or that.emit
    fn(that, event_name, ...)

    that = DiffviewGlobal.emitter
    fn = no_recursion and that.nore_emit or that.emit

    if event_name == "tab_enter" then
      fn(that, "view_enter", view)
    elseif event_name == "tab_leave" then
      fn(that, "view_enter", view)
    end
  end
end

function M.emit(event_name, ...)
  _emit(false, event_name, ...)
end

function M.nore_emit(event_name, ...)
  _emit(true, event_name, ...)
end

M.init()

return M
