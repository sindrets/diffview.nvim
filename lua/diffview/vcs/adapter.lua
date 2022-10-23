local oop = require('diffview.oop')
local utils = require('diffview.utils')
local logger = require('diffview.logger')

local M = {}

---@class vcs.adapter.LayoutOpt
---@field default_layout Diff2
---@field merge_layout Layout

---@class VCSAdapter: diffview.Object
---@field bootstrap boolean[]
---@field context string[]
local VCSAdapter = oop.create_class('VCSAdapter')

function VCSAdapter:init(path)
  self.bootstrap = {
    done = false,
    ok = false,
    version = {},
    version_string = {},
  }
  self.ctx = {}
end

function VCSAdapter:run_bootstrap()
  self.bootstrap.done = true
  self.bootstrap.ok = true
end

function VCSAdapter:get_command()
  oop.abstract_stub()
end

---@param args string[]
---@return string[] args to show commit content
function VCSAdapter:get_show_args(args)
  oop.abstract_stub()
end

function VCSAdapter:get_context(path)
  return {}
end

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

function VCSAdapter:file_history_options(range, args)
  oop.abstract_stub()
end

---@class vcs.adapter.FileHistoryWorkerSpec : git.utils.LayoutOpt

---@param thread thread
---@param log_opt ConfigLogOptions
---@param opt vcs.adapter.FileHistoryWorkerSpec
---@param co_state table
---@param callback function
function VCSAdapter:file_history_worker(thread, log_opt, opt, co_state, callback)
  oop.abstract_stub()
end


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


---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function VCSAdapter:is_binary(path, rev)
  oop.abstract_stub()
end


M.VCSAdapter = VCSAdapter
return M
