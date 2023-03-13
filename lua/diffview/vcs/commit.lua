local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@class Commit : diffview.Object
---@field hash string
---@field author string
---@field time number
---@field time_offset number
---@field date string
---@field iso_date string
---@field rel_date string
---@field ref_names string
---@field subject string
---@field body string
---@field diff? diff.FileEntry[]
local Commit = oop.create_class("Commit")

function Commit:init(opt)
  self.hash = opt.hash
  self.author = opt.author
  self.time = opt.time
  self.rel_date = opt.rel_date
  self.ref_names = opt.ref_names ~= "" and opt.ref_names or nil
  self.subject = opt.subject
  self.body = opt.body
  self.diff = opt.diff
end

---@diagnostic disable: unused-local, missing-return

---@param rev_arg string
---@param adapter VCSAdapter
---@return Commit?
function Commit.from_rev_arg(rev_arg, adapter)
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---@param rev Rev
---@param adapter VCSAdapter
---@return Commit?
function Commit.from_rev(rev, adapter)
  assert(rev.type == RevType.COMMIT, "Rev must be of type COMMIT!")

  return Commit.from_rev_arg(rev.commit, adapter)
end

function Commit.parse_time_offset(iso_date)
  local sign, h, m = vim.trim(iso_date):match("([+-])(%d%d):?(%d%d)$")
  local offset = tonumber(h) * 60 * 60 + tonumber(m) * 60

  if sign == "-" then
    offset = -offset
  end

  return offset
end

function Commit.time_to_iso(time, time_offset)
  local iso = os.date("%Y-%m-%d %H:%M:%S", time + time_offset)
  local sign = utils.sign(time_offset)
  time_offset = math.abs(time_offset)
  local tm = (time_offset - (time_offset % 60)) / 60
  local m = tm % 60
  local h = (tm - (tm % 60)) / 60

  return string.format(
    "%s %s%s%s",
    iso,
    sign < 0 and "-" or "+",
    utils.str_left_pad(tostring(h), 2, "0"),
    utils.str_left_pad(tostring(m), 2, "0")
  )
end

M.Commit = Commit
return M
