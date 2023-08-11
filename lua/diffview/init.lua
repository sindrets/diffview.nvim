if not require("diffview.bootstrap") then
  return
end

local hl = require("diffview.hl")
local lazy = require("diffview.lazy")

local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"

local api = vim.api
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  -- Fix the strange behavior that "<afile>" expands non-files
  -- as file name in some cases.
  --
  -- Ref:
  --  * sindrets/diffview.nvim#369
  --  * neovim/neovim#23943
  local function get_tabnr(state)
    if vim.fn.has("nvim-0.9.2") ~= 1 then
      return tonumber(state.match)
    else
      return tonumber(state.file)
    end
  end

  local au = api.nvim_create_autocmd

  -- Set up highlighting
  hl.setup()

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
      M.close(get_tabnr(state))
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
      M.emit("win_closed", get_tabnr(state))
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
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewOpened", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_closed", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewClosed", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_enter", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewEnter", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_leave", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewLeave", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_post_layout", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewPostLayout", modeline = false })
  end)
  DiffviewGlobal.emitter:on("diff_buf_read", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufRead", modeline = false })
  end)
  DiffviewGlobal.emitter:on("diff_buf_win_enter", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter", modeline = false })
  end)

  -- Set up completion wrapper used by `vim.ui.input()`
  vim.cmd([[
    function! Diffview__ui_input_completion(...) abort
      return luaeval("DiffviewGlobal.state.current_completer(
            \ unpack(vim.fn.eval('a:000')))")
    endfunction
  ]])
end

---@param args string[]
function M.open(args)
  local view = lib.diffview_open(args)
  if view then
    view:open()
  end
end

---@param range? { [1]: integer, [2]: integer }
---@param args string[]
function M.file_history(range, args)
  local view = lib.file_history(range, args)
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

function M.completion(_, cmd_line, cur_pos)
  local ctx = arg_parser.scan(cmd_line, { cur_pos = cur_pos, allow_ex_range = true })
  local cmd = ctx.args[1]

  if cmd and M.completers[cmd] then
    return arg_parser.process_candidates(M.completers[cmd](ctx), ctx)
  end
end

---Create a temporary adapter to get relevant completions
---@return VCSAdapter?
function M.get_adapter()
    local cfile = pl:vim_expand("%")
    local top_indicators = utils.vec_join(
      vim.bo.buftype == ""
          and pl:absolute(cfile)
          or nil,
      pl:realpath(".")
    )

    local err, adapter = vcs.get_adapter({ top_indicators = top_indicators })

    if err then
      logger:warn("[completion] Failed to create adapter: " .. err)
    end

    return adapter
end

M.completers = {
  ---@param ctx CmdLineContext
  DiffviewOpen = function(ctx)
    local has_rev_arg = false
    local adapter = M.get_adapter()

    for i = 2, math.min(#ctx.args, ctx.divideridx) do
      if ctx.args[i]:sub(1, 1) ~= "-" and i ~= ctx.argidx then
        has_rev_arg = true
        break
      end
    end

    local candidates = {}

    if ctx.argidx > ctx.divideridx then
      if adapter then
        utils.vec_push(candidates, unpack(adapter:path_candidates(ctx.arg_lead)))
      else
        utils.vec_push(candidates, unpack(vim.fn.getcompletion(ctx.arg_lead, "file", 0)))
      end
    elseif adapter then
      if not has_rev_arg and ctx.arg_lead:sub(1, 1) ~= "-" then
        utils.vec_push(candidates, unpack(adapter.comp.open:get_all_names()))
        utils.vec_push(candidates, unpack(adapter:rev_candidates(ctx.arg_lead, {
          accept_range = true,
        })))
      else
        utils.vec_push(candidates, unpack(
          adapter.comp.open:get_completion(ctx.arg_lead)
          or adapter.comp.open:get_all_names()
        ))
      end
    end

    return candidates
  end,
  ---@param ctx CmdLineContext
  DiffviewFileHistory = function(ctx)
    local adapter = M.get_adapter()
    local candidates = {}

    if adapter then
      utils.vec_push(candidates, unpack(
        adapter.comp.file_history:get_completion(ctx.arg_lead)
        or adapter.comp.file_history:get_all_names()
      ))
      utils.vec_push(candidates, unpack(adapter:path_candidates(ctx.arg_lead)))
    else
      utils.vec_push(candidates, unpack(vim.fn.getcompletion(ctx.arg_lead, "file", 0)))
    end

    return candidates
  end,
}

function M.update_colors()
  hl.setup()
  lib.update_colors()
end

local function _emit(no_recursion, event_name, ...)
  local view = lib.get_current_view()

  if view and not view.closing:check() then
    local that = view.emitter
    local fn = no_recursion and that.nore_emit or that.emit
    fn(that, event_name, ...)

    that = DiffviewGlobal.emitter
    fn = no_recursion and that.nore_emit or that.emit

    if event_name == "tab_enter" then
      fn(that, "view_enter", view)
    elseif event_name == "tab_leave" then
      fn(that, "view_leave", view)
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
