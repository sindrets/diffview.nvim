local oop = require("diffview.oop")
local M = {}

---@class Commit
---@field hash string
---@field author string
---@field date string
---@field subject string
---@field body string
local Commit = oop.Object
Commit = oop.create_class("Commit")

function Commit:init(opt)
  self.hash = opt.hash
  self.author = opt.author
  self.date = opt.date
  self.subject = opt.subject
  self.body = opt.body
end

M.Commit = Commit
return M
