local a = vim.api
local M = {}

---@class HlData
---@field line_idx integer
---@field group string
---@field first integer
---@field last integer

---@class RenderData
---@field lines string[]
---@field hl HlData[]
---@field namespace integer
local RenderData = {}
RenderData.__index = RenderData

---RenderData constructor.
---@return RenderData
function RenderData:new(ns_name)
  local this = {
    lines = {},
    hl = {},
    namespace = a.nvim_create_namespace(ns_name)
  }
  setmetatable(this, self)
  return this
end

---Render the given render data to the given buffer.
---@param bufid integer
---@param data RenderData
function M.render(bufid, data)
  if not a.nvim_buf_is_loaded(bufid) then return end

  local was_modifiable = a.nvim_buf_get_option(bufid, "modifiable")
  a.nvim_buf_set_option(bufid, "modifiable", true)

  a.nvim_buf_set_lines(bufid, 0, -1, false, data.lines)
  a.nvim_buf_clear_namespace(bufid, data.namespace, 0, -1)
  for _, hl in ipairs(data.hl) do
    a.nvim_buf_add_highlight(bufid, data.namespace, hl.group, hl.line_idx, hl.first, hl.last)
  end

  a.nvim_buf_set_option(bufid, "modifiable", was_modifiable)
end

local git_status_hl_map = {
  ["A"] = "diffAdded",   -- Added
  ["?"] = "diffAdded",   -- Untracked
  ["M"] = "diffChanged", -- Modified
  ["R"] = "diffChanged", -- Renamed
  ["C"] = "diffChanged", -- Copied
  ["T"] = "diffChanged", -- Type changed
  ["U"] = "diffChanged", -- Unmerged
  ["X"] = "diffChanged", -- Unknown
  ["D"] = "diffRemoved", -- Deleted
  ["B"] = "diffRemoved", -- Broken
}

function M.get_git_hl(status)
  return git_status_hl_map[status]
end

M.RenderData = RenderData
return M
