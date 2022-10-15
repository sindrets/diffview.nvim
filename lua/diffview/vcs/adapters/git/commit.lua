local lazy = require("diffview.lazy")
local oop = require('diffview.oop')
local utils = require("diffview.utils")
local Commit = require('diffview.vcs.commit').Commit

---@module "diffview.vcs.utils"
local git = lazy.require("diffview.vcs.utils")

---@type ERevType|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType")


local M = {}


---@class GitCommit : Commit
---@field hash string
---@field author string
---@field time number
---@field time_offset number
---@field date string
---@field rel_date string
---@field ref_names string
---@field subject string
---@field body string
local GitCommit = oop.create_class('GitCommit', Commit)

function GitCommit:init(opt)
  GitCommit:super().init(self, opt)
end

---@param rev_arg string
---@param git_toplevel string
---@return GitCommit?
function GitCommit.from_rev_arg(rev_arg, git_toplevel)
  local out, code = git.exec_sync({
    "show",
    "--pretty=format:%H %P%n%an%n%ad%n%ar%n  %s",
    "--date=raw",
    "--name-status",
    rev_arg,
    "--",
  }, git_toplevel)

  if code ~= 0 then
    return
  end

  local right_hash, _, _ = unpack(utils.str_split(out[1]))
  local time, time_offset = unpack(utils.str_split(out[3]))

  return GitCommit({
    hash = right_hash,
    author = out[2],
    time = tonumber(time),
    time_offset = time_offset,
    rel_date = out[4],
    subject = out[5]:sub(3),
  })
end

---@param rev Rev
---@param git_toplevel string
---@return GitCommit?
function GitCommit.from_rev(rev, git_toplevel)
  assert(rev.type == RevType.COMMIT, "Rev must be of type COMMIT!")

  return GitCommit.from_rev_arg(rev.commit, git_toplevel)
end

function GitCommit.parse_time_offset(iso_date)
  local sign, h, m = vim.trim(iso_date):match("([+-])(%d%d):?(%d%d)$")
  local offset = tonumber(h) * 60 * 60 + tonumber(m) * 60

  if sign == "-" then
    offset = -offset
  end

  return offset
end

M.GitCommit = GitCommit
return M
