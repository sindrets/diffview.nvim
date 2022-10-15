local oop = require('diffview.oop')
local utils = require('diffview.utils')
local logger = require('diffview.logger')

local M = {}

local VCSAdapter = oop.create_class('VCSAdapter')

function VCSAdapter:init(path)
  self.path = path
  self.bootstrap = {
    done = false,
    ok = false,
  }
  self.context = self:get_context(path)
end

function VCSAdapter:run_bootstrap()
  oop.abstract_stub()
end

function VCSAdapter:get_command()
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

function VCSAdapter:exec_sync(args, cwd_or_opt)
  if not self.bootstrap.done then
    self:run_bootstrap()
  end

  return utils.system_list(
    vim.tbl_flatten({ self:get_command(), args }),
    cwd_or_opt
  )
end


M.VCSAdapter = VCSAdapter
return M
