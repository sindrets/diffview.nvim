local oop = require("diffview.oop")
local utils = require("diffview.utils")
local M = {}

---@class Commit
---@field hash string
---@field author string
---@field time number
---@field time_offset number
---@field date string
---@field rel_date string
---@field subject string
---@field body string
local Commit = oop.Object
Commit = oop.create_class("Commit")

function Commit:init(opt)
  self.hash = opt.hash
  self.author = opt.author
  self.time = opt.time
  self.rel_date = opt.rel_date
  self.subject = opt.subject
  self.body = opt.body

  if opt.time_offset then
    self.time_offset = Commit.parse_time_offset(opt.time_offset)
    self.time = self.time - self.time_offset
  else
    self.time_offset = 0
  end

  self.iso_date = Commit.time_to_iso(self.time, self.time_offset)
end

function Commit.parse_time_offset(iso_date)
  local sign, h, m = vim.trim(iso_date):match("([+-])(%d%d):?(%d%d)$")
  local offset = tonumber(h) * 60 * 60 + tonumber(m) * 60
  if sign == "-" then
    offset = - offset
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
