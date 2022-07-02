local oop = require("diffview.oop")
local M = {}

---@class LogEntry : Object
---@field path_args string[]
---@field commit Commit
---@field files FileEntry[]
---@field status string
---@field stats GitStats
---@field single_file boolean
---@field folded boolean
local LogEntry = oop.create_class("LogEntry")

function LogEntry:init(opt)
  self.path_args = opt.path_args
  self.commit = opt.commit
  self.files = opt.files
  self.folded = true
  self.single_file = opt.single_file
  self:update_status()
  self:update_stats()
end

function LogEntry:destroy()
  for _, file in ipairs(self.files) do
    file:destroy()
  end
end

function LogEntry:update_status()
  self.status = nil
  local missing_status = 0

  for _, file in ipairs(self.files) do
    if not file.status then
      missing_status = missing_status + 1
    else
      if self.status and file.status ~= self.status then
        self.status = "M"
        return
      elseif self.status ~= file.status then
        self.status = file.status
      end
    end
  end

  if missing_status < #self.files and not self.status then
    self.status = "X"
  end
end

function LogEntry:update_stats()
  self.stats = { additions = 0, deletions = 0 }
  local missing_stats = 0

  for _, file in ipairs(self.files) do
    if not file.stats then
      missing_stats = missing_stats + 1
    else
      self.stats.additions = self.stats.additions + file.stats.additions
      self.stats.deletions = self.stats.deletions + file.stats.deletions
    end
  end

  if missing_stats == #self.files then
    self.stats = nil
  end
end

M.LogEntry = LogEntry
return M
