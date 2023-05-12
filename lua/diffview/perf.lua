local oop = require("diffview.oop")
local utils = require("diffview.utils")

local uv = vim.loop

local M = {}

---@class PerfTimer : diffview.Object
---@operator call : PerfTimer
---@field subject string|nil
---@field first integer Start time (ns)
---@field last integer Stop time (ns)
---@field final_time number Final time (ms)
---@field laps number[] List of lap times (ms)
local PerfTimer = oop.create_class("PerfTimer")

---PerfTimer constructor.
---@param subject string|nil
function PerfTimer:init(subject)
  self.subject = subject
  self.laps = {}
  self.first = uv.hrtime()
end

function PerfTimer:reset()
  self.laps = {}
  self.first = uv.hrtime()
  self.final_time = nil
end

---Record a lap time.
---@param subject string|nil
function PerfTimer:lap(subject)
  self.laps[#self.laps + 1] = {
    subject or #self.laps + 1,
    (uv.hrtime() - self.first) / 1000000,
  }
end

---Set final time.
---@return number
function PerfTimer:time()
  self.last = uv.hrtime() - self.first
  self.final_time = self.last / 1000000

  return self.final_time
end

function PerfTimer:__tostring()
  if not self.final_time then
    self:time()
  end

  if #self.laps == 0 then
    return string.format(
      "%s %.3f ms",
      utils.str_right_pad((self.subject or "TIME") .. ":", 24),
      self.final_time
    )
  else
    local s = (self.subject or "LAPS") .. ":\n"
    local last = 0

    for _, lap in ipairs(self.laps) do
      s = s
        .. string.format(
          ">> %s %.3f ms\t(%.3f ms)\n",
          utils.str_right_pad(lap[1], 36),
          lap[2],
          lap[2] - last
        )
      last = lap[2]
    end

    return s .. string.format("== %s %.3f ms", utils.str_right_pad("FINAL TIME", 36), self.final_time)
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
