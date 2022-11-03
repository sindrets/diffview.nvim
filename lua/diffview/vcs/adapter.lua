local oop = require('diffview.oop')
local utils = require('diffview.utils')
local logger = require('diffview.logger')
local arg_parser = require('diffview.arg_parser')
local RevType = require("diffview.vcs.rev").RevType
local Rev = require("diffview.vcs.rev").Rev

local M = {}

---@class vcs.adapter.LayoutOpt
---@field default_layout Diff2
---@field merge_layout Layout


---@class vcs.adapter.VCSAdapter.Bootstrap
---@field done boolean # Did the bootstrapping
---@field ok boolean # Bootstrapping was successful
---@field version table
---@field version_string string
---@field target_version table
---@field target_version_string string

---@class vcs.adapter.VCSAdapter.Flags
---@field switches FlagOption[]
---@field options FlagOption[]

---@class vcs.adapter.VCSAdapter.Ctx
---@field toplevel string # VCS repository toplevel directory
---@field dir string # VCS directory
---@field path_args string[] # Extra path arguments

---@class VCSAdapter: diffview.Object
---@field bootstrap vcs.adapter.VCSAdapter.Bootstrap
---@field ctx vcs.adapter.VCSAdapter.Ctx
---@field flags vcs.adapter.VCSAdapter.Flags
local VCSAdapter = oop.create_class('VCSAdapter')

VCSAdapter.Rev = Rev

---@class vcs.adapter.VCSAdapter.Opt
---@field cpath string? # CWD path
---@field toplevel string # VCS toplevel path
---@field path_args string[] # Extra path arguments

---@param opt vcs.adapter.VCSAdapter.Opt
function VCSAdapter:init(opt)
  self.bootstrap = {
    done = false,
    ok = false,
    version = {},
    version_string = "",
  }
  self.ctx = {}

  self.comp = {
    file_history = arg_parser.FlagValueMap(),
    open = arg_parser.FlagValueMap(),
  }
end

function VCSAdapter:run_bootstrap()
  self.bootstrap.done = true
  self.bootstrap.ok = true
end

---@diagnostic disable: unused-local, missing-return

---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function VCSAdapter:is_binary(path, rev)
  oop.abstract_stub()
end

---Initialize completion parameters
function VCSAdapter:init_completion()
  oop.abstract_stub()
end

---@class RevCompletionSpec
---@field accept_range boolean

---Completion for revisions.
---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function VCSAdapter:rev_completion(arg_lead, opt)
  oop.abstract_stub()
end

---@return Rev?
function VCSAdapter:head_rev()
  oop.abstract_stub()
end

---@return string[] # path to binary for VCS command
function VCSAdapter:get_command()
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---@return string cmd The VCS binary.
function VCSAdapter:bin()
  return self:get_command()[1]
end

---@return string[] args The default VCS args.
function VCSAdapter:args()
  return utils.vec_slice(self:get_command(), 2)
end


---Execute a VCS command synchronously.
---@param args string[]
---@param cwd_or_opt? string|utils.system_list.Opt
---@return string[] stdout
---@return integer code
---@return string[] stderr
---@overload fun(args: string[], cwd: string?)
---@overload fun(args: string[], opt: utils.system_list.Opt?)
function VCSAdapter:exec_sync(args, cwd_or_opt)
  if not self.bootstrap.done then
    self:run_bootstrap()
  end

  return utils.system_list(
    vim.tbl_flatten({ self:get_command(), args }),
    cwd_or_opt
  )
end


---@param thread thread
---@param ok boolean
---@param result any
---@return boolean ok
---@return any result
function VCSAdapter:handle_co(thread, ok, result)
  if not ok then
    local err_msg = utils.vec_join(
      "Coroutine failed!",
      debug.traceback(thread, result, 1)
    )
    utils.err(err_msg, true)
    logger.s_error(table.concat(err_msg, "\n"))
  end
  return ok, result
end

-- File History

---@diagnostic disable: unused-local, missing-return

---@param args string[]
---@return string?[] args to show commit content
function VCSAdapter:get_show_args(args)
  oop.abstract_stub()
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param args string[]
---@return string[] # Options to show file history
function VCSAdapter:file_history_options(range, paths, args)
  oop.abstract_stub()
end

---@class vcs.adapter.FileHistoryWorkerSpec : vcs.adapter.LayoutOpt

---@param thread thread
---@param log_opt ConfigLogOptions
---@param opt vcs.adapter.FileHistoryWorkerSpec
---@param co_state table
---@param callback function
function VCSAdapter:file_history_worker(thread, log_opt, opt, co_state, callback)
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---@param log_opt ConfigLogOptions
---@param opt vcs.adapter.FileHistoryWorkerSpec
---@param callback function
---@return fun() finalizer
function VCSAdapter:file_history(log_opt, opt, callback)
  local thread

  local co_state = {
    shutdown = false,
  }

  thread = coroutine.create(function()
    self:file_history_worker(thread, log_opt, opt, co_state, callback)
  end)

  self:handle_co(thread, coroutine.resume(thread))

  return function()
    co_state.shutdown = true
  end
end

-- Diff View

---@diagnostic disable: unused-local, missing-return

---Convert revs to rev args.
---@param left Rev
---@param right Rev
---@return string[]
function VCSAdapter:rev_to_args(left, right)
  oop.abstract_stub()
end

---Arguments to show name and status of files
---@param args string?[] Extra args
---@return string[]
function VCSAdapter:get_namestat_args(args)
  oop.abstract_stub()
end

---Arguments to show number of changes to files
---@param args string?[] Extra args
---@return string[]
function VCSAdapter:get_numstat_args(args)
  oop.abstract_stub()
end

---Arguments to list all files
---@param args string?[] Extra args
---@return string[]
function VCSAdapter:get_files_args(args)
  oop.abstract_stub()
end

---Restore a file to the requested state
---@param path string # file to restore
---@param kind '"staged"'|'"working"'
---@param commit string
---@return string? Command to undo the restore
function VCSAdapter:restore_file(path, kind, commit)
  oop.abstract_stub()
end

---Add file(s)
---@param paths string[]
---@return boolean # add was successful
function VCSAdapter:add_files(paths)
  oop.abstract_stub()
end

---Reset file(s)
---@param paths string?[]
---@return boolean # reset was successful
function VCSAdapter:reset_files(paths)
  oop.abstract_stub()
end

---@param args string[]
---@return {left: string, right: string, options: string[]}
function VCSAdapter:diffview_options(args)
  oop.abstract_stub()
end

---Check if status for untracked files is disabled
---@return boolean
function VCSAdapter:show_untracked()
  oop.abstract_stub()
end

---Restore file
---@param path string
---@param kind '"staged"' | '"working"'
---@param commit string?
---@return boolean # Restore was successful
function VCSAdapter:file_restore(path, kind, commit)
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function VCSAdapter:rev_to_pretty_string(left, right)
  if left.track_head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function VCSAdapter:has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---@class FlagOption : string[]
---@field key string
---@field prompt_label string
---@field prompt_fmt string
---@field select string[]
---@field completion string|fun(panel: FHOptionPanel): function
---@field transform fun(values: string[]): any # Transform the values given by the user.
---@field render_value fun(option: FlagOption, value: string|string[]): boolean, string # Render the flag value in the panel.
---@field render_default fun(options: FlagOption, value: string|string[]): string # Render the default text for the input().

VCSAdapter.flags = {
  ---@type FlagOption[]
  switches = {},
  ---@type FlagOption[]
  options = {},
}

M.VCSAdapter = VCSAdapter
return M
