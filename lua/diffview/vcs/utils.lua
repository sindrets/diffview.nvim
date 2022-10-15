local utils = require("diffview.utils")

local M = {}

---@enum JobStatus
local JobStatus = {
  SUCCESS = 1,
  PROGRESS = 2,
  ERROR = 3,
  KILLED = 4,
  FATAL = 5,
}

M.JobStatus = JobStatus
return M
