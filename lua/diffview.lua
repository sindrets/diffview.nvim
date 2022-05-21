if not require("diffview.bootstrap") then
  return
end

local arg_parser = require("diffview.arg_parser")
local colors = require("diffview.colors")
local config = require("diffview.config")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

local M = {}

---@type FlagValueMap
local comp_open = arg_parser.FlagValueMap()
comp_open:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
comp_open:put({ "cached", "staged" }, { "true", "false" })
comp_open:put({ "imply-local" }, { "true", "false" })
comp_open:put({ "C" }, function(_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "dir")
end)
comp_open:put({ "selected-file" }, function (_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "file")
end)

---@type FlagValueMap
local comp_file_history = arg_parser.FlagValueMap()
comp_file_history:put({ "base" }, function(_, arg_lead)
  return M.rev_completion(arg_lead)
end)
comp_file_history:put({ "range" }, function(_, arg_lead)
  return M.rev_completion(arg_lead, { accept_range = true })
end)
comp_file_history:put({ "C" }, function(_, arg_lead)
  return vim.fn.getcompletion(arg_lead, "dir")
end)

function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  colors.setup()

  -- Set up autocommand emitters
  DiffviewGlobal.emitter:on("view_opened", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewOpened")
  end)
  DiffviewGlobal.emitter:on("view_closed", function(_)
    vim.cmd("do <nomodeline> User DiffviewViewClosed")
  end)
  DiffviewGlobal.emitter:on("diff_buf_read", function(_)
    vim.cmd("do User DiffviewDiffBufRead")
  end)
  DiffviewGlobal.emitter:on("diff_buf_win_enter", function(_)
    vim.cmd("do User DiffviewDiffBufWinEnter")
  end)
end

function M.open(...)
  local view = lib.diffview_open(utils.tbl_pack(...))
  if view then
    view:open()
  end
end

function M.file_history(...)
  local view = lib.file_history(utils.tbl_pack(...))
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
  if M.completers[args[1]] then
    return M.filter_completion(arg_lead, M.completers[args[1]](args, argidx, divideridx, arg_lead))
  end
end

function M.rev_candidates(git_root, git_dir)
  local cfile, fpath
  if not (git_root and git_dir) then
    cfile = utils.path:vim_expand("%")
    fpath =
        vim.bo.buftype == ""
        and utils.path:readable(cfile)
        and utils.path:parent(cfile)
        or "."
  end

  git_root = git_root or require("diffview.git.utils").toplevel(fpath)
  git_dir = git_dir or require("diffview.git.utils").git_dir(fpath)
  if not (git_root and git_dir) then
    return {}
  end

  -- stylua: ignore start
  local targets = {
    "HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
    "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"
  }
  local heads = vim.tbl_filter(
    function(name) return vim.tbl_contains(targets, name) end,
    vim.tbl_map(
      function(v) return utils.path:basename(v) end,
      vim.fn.glob(git_dir .. "/*", false, true)
    )
  )
  -- stylua: ignore end
  local revs = utils.system_list(
    { "git", "rev-parse", "--symbolic", "--branches", "--tags", "--remotes" },
    git_root,
    true
  )
  local stashes = utils.system_list(
    { "git", "stash", "list", "--pretty=format:%gd" },
    git_root,
    true
  )

  return utils.vec_join(heads, revs, stashes)
end

---@class RevCompletionSpec
---@field accept_range boolean
---@field git_root string
---@field git_dir string

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

M.completers = {
  DiffviewOpen = function(args, argidx, divideridx, arg_lead)
    local cfile = utils.path:vim_expand("%")
    local fpath =
        vim.bo.buftype == ""
        and utils.path:readable(cfile)
        and utils.path:parent(cfile)
        or "."
    local git_dir = require("diffview.git.utils").git_dir(fpath)
    local git_root = require("diffview.git.utils").toplevel(fpath)
    local has_rev_arg = false

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

function M.emit(event_name, ...)
  local view = lib.get_current_view()
  if view and not view.closing then
    view.emitter:emit(event_name, ...)
  end
end

M.init()

return M
