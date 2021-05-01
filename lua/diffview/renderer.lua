local a = vim.api
local M = {}

---@class HlData
---@field group string
---@field line_idx integer
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

function RenderData:add_hl(group, line_idx, first, last)
  table.insert(self.hl, {
      group = group,
      line_idx = line_idx,
      first = first,
      last = last
    })
end

function RenderData:clear()
  self.lines = {}
  self.hl = {}
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
  ["A"] = "DiffviewStatusAdded",
  ["?"] = "DiffviewStatusAdded",
  ["M"] = "DiffviewStatusModified",
  ["R"] = "DiffviewStatusRenamed",
  ["C"] = "DiffviewStatusCopied",
  ["T"] = "DiffviewStatusTypeChanged",
  ["U"] = "DiffviewStatusUnmerged",
  ["X"] = "DiffviewStatusUnknown",
  ["D"] = "DiffviewStatusDeleted",
  ["B"] = "DiffviewStatusBroken",
}

function M.get_git_hl(status)
  return git_status_hl_map[status]
end

function M.get_file_icon(name, ext, render_data, line_idx, offset)
  local web_devicons = require'nvim-web-devicons'
  local icon, hl = web_devicons.get_icon(name, ext)

  if icon then
    if hl then
      render_data:add_hl(hl, line_idx, offset, offset + string.len(icon) + 1)
    end
    return icon .. " "
  end

  return ""
end

M.RenderData = RenderData
return M
