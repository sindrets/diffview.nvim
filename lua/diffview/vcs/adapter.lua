local Job = require("diffview.job").Job
local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local Rev = lazy.access("diffview.vcs.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local await = async.await
local logger = DiffviewGlobal.logger

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
---@field path_args string[] # Resolved path arguments

---@class VCSAdapter: diffview.Object
---@field bootstrap vcs.adapter.VCSAdapter.Bootstrap
---@field ctx vcs.adapter.VCSAdapter.Ctx
---@field flags vcs.adapter.VCSAdapter.Flags
local VCSAdapter = oop.create_class("VCSAdapter")

VCSAdapter.Rev = Rev
VCSAdapter.config_key = nil
VCSAdapter.bootstrap = {
  done = false,
  ok = false,
  version = {},
}

function VCSAdapter.run_bootstrap()
  VCSAdapter.bootstrap.done = true
  VCSAdapter.bootstrap.ok = false
end

---@diagnostic disable: unused-local, missing-return

---@abstract
---@param path_args string[] # Raw path args
---@param cpath string? # Cwd path given by the `-C` flag option
---@return string[] path_args # Resolved path args
---@return string[] top_indicators # Top-level indicators
function VCSAdapter.get_repo_paths(path_args, cpath) oop.abstract_stub() end

---Try to find the top-level of a working tree by using the given indicative
---paths.
---@abstract
---@param top_indicators string[] A list of paths that might indicate what working tree we are in.
---@return string? err
---@return string toplevel # Absolute path
function VCSAdapter.find_toplevel(top_indicators) oop.abstract_stub() end

---@diagnostic enable: unused-local, missing-return

---@class vcs.adapter.VCSAdapter.Opt
---@field cpath string? # CWD path
---@field toplevel string # VCS toplevel path
---@field path_args string[] # Extra path arguments

function VCSAdapter:init()
  self.ctx = {}
  self.comp = {
    file_history = arg_parser.FlagValueMap(),
    open = arg_parser.FlagValueMap(),
  }
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
function VCSAdapter:rev_candidates(arg_lead, opt)
  oop.abstract_stub()
end

---@return Rev?
function VCSAdapter:head_rev()
  oop.abstract_stub()
end

---Get the hash for a file's blob in a given rev.
---@param path string
---@param rev_arg string?
---@return string?
function VCSAdapter:file_blob_hash(path, rev_arg)
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
---@overload fun(self: VCSAdapter, args: string[], cwd: string?)
---@overload fun(self: VCSAdapter, args: string[], opt: utils.system_list.Opt?)
function VCSAdapter:exec_sync(args, cwd_or_opt)
  if not self:class().bootstrap.done then self:class().run_bootstrap() end

  local cmd = vim.tbl_flatten({ self:get_command(), args })

  if not self:class().bootstrap.ok then
    logger:error(
      ("[VCSAdapter] Can't exec adapter command because bootstrap failed! Cmd: %s")
      :format(table.concat(cmd, " "))
    )
    return
  end

  return utils.system_list(cmd, cwd_or_opt)
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
    logger:error(table.concat(err_msg, "\n"))
  end
  return ok, result
end

-- File History

---@diagnostic disable: unused-local, missing-return

---@param path string
---@param rev Rev?
---@return string[] args to show commit content
function VCSAdapter:get_show_args(path, rev)
  oop.abstract_stub()
end

---@param args string[]
---@return string[] args to show commit log message
function VCSAdapter:get_log_args(args)
  oop.abstract_stub()
end

---@class vcs.MergeContext
---@field ours { hash: string, ref_names: string? }
---@field theirs { hash: string, ref_names: string? }
---@field base { hash: string, ref_names: string? }

---@return vcs.MergeContext?
function VCSAdapter:get_merge_context()
  oop.abstract_stub()
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
---@return string[] # Options to show file history
function VCSAdapter:file_history_options(range, paths, argo)
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
---@return Closeable
function VCSAdapter:file_history(log_opt, opt, callback)
  local thread

  local co_state = {
    shutdown = false,
  }

  thread = coroutine.create(function()
    self:file_history_worker(thread, log_opt, opt, co_state, callback)
  end)

  self:handle_co(thread, coroutine.resume(thread))

  return {
    close = function()
      co_state.shutdown = true
    end,
  }
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
---@param paths string[]?
---@return boolean # reset was successful
function VCSAdapter:reset_files(paths)
  oop.abstract_stub()
end

---@param argo ArgObject
---@return {left: string, right: string, options: string[]}
function VCSAdapter:diffview_options(argo)
  oop.abstract_stub()
end

---@class VCSAdapter.show_untracked.Opt
---@field dv_opt? DiffViewOptions
---@field revs? { left: Rev, right: Rev }

---Check whether untracked files should be listed.
---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function VCSAdapter:show_untracked(opt)
  oop.abstract_stub()
end

---Restore file
---@param path string
---@param kind vcs.FileKind
---@param commit string?
---@return boolean success
---@return string? undo # If the adapter supports it: a command that will undo the restoration.
function VCSAdapter:file_restore(path, kind, commit)
  oop.abstract_stub()
end

---Update the index entry for a given file with the contents of an index buffer.
---@param file vcs.File
---@return boolean success
function VCSAdapter:stage_index_file(file)
  oop.abstract_stub()
end

---@param self VCSAdapter
---@param left Rev
---@param right Rev
---@param args string[]
---@param kind vcs.FileKind
---@param opt vcs.adapter.LayoutOpt
---@param callback function
VCSAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  oop.abstract_stub()
end)

---@param self VCSAdapter
---@param left Rev
---@param right Rev
---@param opt vcs.adapter.LayoutOpt
---@param callback? function
VCSAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  oop.abstract_stub()
end)

---@diagnostic enable: unused-local, missing-return

---@param self VCSAdapter
---@param path string
---@param rev? Rev
---@param callback fun(stderr: string[]?, stdout: string[]?)
VCSAdapter.show = async.wrap(function(self, path, rev, callback)
  local job = Job({
    command = self:bin(),
    args = self:get_show_args(path, rev),
    cwd = self.ctx.toplevel,
    ---@param j diffview.Job
    on_exit = async.void(function(j)
      local context = "VCSAdapter.show()"
      utils.handle_job(j, {
        fail_on_empty = true,
        context = context,
        debug_opt = { no_stdout = true, context = context },
      })

      if j.code ~= 0 then
        callback(j.stderr or {}, nil)
        return
      end

      local out_status

      if #j.stdout == 0 then
        await(async.scheduler())
        out_status = await(vcs_utils.ensure_output(2, { j }, context))
      end

      if out_status == JobStatus.ERROR then
        callback(j.stderr or {}, nil)
        return
      end

      callback(nil, j.stdout)
    end),
  })
  -- Problem: Running multiple 'show' jobs simultaneously may cause them to fail
  -- silently.
  -- Solution: queue them and run them one after another.
  vcs_utils.queue_sync_job(job)
end)

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

VCSAdapter.flags = {
  ---@type FlagOption[]
  switches = {},
  ---@type FlagOption[]
  options = {},
}

---@param arg_lead string
---@return string[]
function VCSAdapter:path_candidates(arg_lead)
  return vim.fn.getcompletion(arg_lead, "file", 0)
end

M.VCSAdapter = VCSAdapter
return M
