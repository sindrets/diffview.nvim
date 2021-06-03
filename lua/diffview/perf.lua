---@diagnostic disable: redefined-local
local oop = require'diffview.oop'
local utils = require'diffview.utils'
local luv = vim.loop
local M = {}

---@class PerfTimer
---@field subject string|nil
---@field first integer Start time (ns)
---@field last integer Stop time (ns)
---@field final_time number Final time (ms)
---@field laps number[] List of lap times (ms)
local PerfTimer = oop.class()

---PerfTimer constructor.
---@param subject string|nil
---@return PerfTimer
function PerfTimer:new(subject)
  local this = {
    subject = subject,
    first = luv.hrtime(),
    laps = {}
  }
  setmetatable(this, self)
  return this
end

---Record a lap time.
function PerfTimer:lap()
  table.insert(self.laps, (luv.hrtime() - self.first) / 1000000)
end

---Set final time.
---@return number
function PerfTimer:time()
  self.last = luv.hrtime() - self.first
  self.final_time = self.last / 1000000
  return self.final_time
end

function PerfTimer:print_result()
  if not self.final_time then self:time() end

  if #self.laps == 0 then
    print(string.format(
      "%s %.2fms",
      utils.str_right_pad((self.subject or "TIME") .. ":", 24),
      self.final_time)
    )
  else
    print((self.subject or "LAPS") .. ":")
    for i, lap in ipairs(self.laps) do
      print(string.format("%s %.2fms", utils.str_right_pad(i, 16), lap))
    end
    print(string.format("%s %.2fms", utils.str_right_pad("FINAL TIME:", 16), self.final_time))
  end
end

---Get the relative performance difference in percent.
---@static
---@param a PerfTimer
---@param b PerfTimer
---@return string
function PerfTimer.difference(a, b)
  local delta = (b.final_time - a.final_time) / a.final_time
  local negative = delta < 0
  return string.format("%s%.2f%%", not negative and "+" or "", delta * 100)
end

M.PerfTimer = PerfTimer
return M
