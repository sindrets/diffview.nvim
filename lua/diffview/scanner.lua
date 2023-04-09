local oop = require("diffview.oop")

---@class Scanner : diffview.Object
---@operator call : Scanner
---@field lines string[]
---@field line_idx integer
local Scanner = oop.create_class("Scanner")

---@param source string|string[]
function Scanner:init(source)
  if type(source) == "table" then
    self.lines = source
  else
    self.lines = vim.split(source, "\r?\n")
  end

  self.line_idx = 0
end

---Peek the nth line after the current line.
---@param n? integer # (default: 1)
---@return string?
function Scanner:peek_line(n)
  return self.lines[self.line_idx + math.max(1, n or 1)]
end

function Scanner:cur_line()
  return self.lines[self.line_idx]
end

function Scanner:cur_line_idx()
  return self.line_idx
end

---Advance the scanner to the next line.
---@return string?
function Scanner:next_line()
  self.line_idx = self.line_idx + 1
  return self.lines[self.line_idx]
end

---Advance the scanner by n lines.
---@param n? integer # (default: 1)
---@return string?
function Scanner:skip_line(n)
  self.line_idx = self.line_idx + math.max(1, n or 1)
  return self.lines[self.line_idx]
end

return Scanner
