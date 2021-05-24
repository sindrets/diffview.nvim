local utils = require'diffview.utils'
local config = require'diffview.config'
local a = vim.api
local M = {}
local web_devicons

---@class HlData
---@field group string
---@field line_idx integer
---@field first integer
---@field last integer

---@class RenderComponent
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field lstart integer
---@field lend integer
---@field height integer
local RenderComponent = utils.class()

---RenderComponent constructor.
---@return RenderComponent
function RenderComponent:new()
  local this = {
    lines = {},
    hl = {},
    components = {},
    lstart = -1,
    lend = -1,
    height = 0
  }
  setmetatable(this, self)
  return this
end

local function create_subcomponents(component, comp_struct, schema)
  local new_comp = component:create_component()
  comp_struct[schema.name] = { comp = new_comp }

  for _, v in ipairs(schema) do
    if v.name then
      local sub_comp = new_comp:create_component()
      comp_struct[v.name] = { comp = sub_comp }
      if #v > 0 then
        create_subcomponents(sub_comp, comp_struct[v.name], v)
      end
    end
  end
end

---Create and add a new component.
---@param schema any
---@return RenderComponent|any
function RenderComponent:create_component(schema)
  local comp_struct
  local new_comp = RenderComponent:new()
  table.insert(self.components, new_comp)

  if schema then
    comp_struct = { comp = new_comp }
    for _, v in ipairs(schema) do
      create_subcomponents(new_comp, comp_struct, v)
    end

    return comp_struct
  end

  return new_comp
end

function RenderComponent:remove_component(component)
  for i, c in ipairs(self.components) do
    if c == component then
      table.remove(self.components, i)
      return true
    end
  end

  return false
end

function RenderComponent:add_line(line)
  table.insert(self.lines, line)
end

function RenderComponent:add_hl(group, line_idx, first, last)
  table.insert(self.hl, {
      group = group,
      line_idx = line_idx,
      first = first,
      last = last
    })
end

function RenderComponent:clear()
  self.lines = {}
  self.hl = {}
  self.lstart = -1
  self.lend = -1
  self.height = 0
  for _, c in ipairs(self.components) do
    c:clear()
  end
end

---@class RenderData
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field namespace integer
local RenderData = utils.class()

---RenderData constructor.
---@return RenderData
function RenderData:new(ns_name)
  local this = {
    lines = {},
    hl = {},
    components = {},
    namespace = a.nvim_create_namespace(ns_name)
  }
  setmetatable(this, self)
  return this
end

---Create and add a new component.
---@param schema any
---@return RenderComponent|any
function RenderData:create_component(schema)
  local comp_struct
  local new_comp = RenderComponent:new()
  table.insert(self.components, new_comp)

  if schema then
    comp_struct = { comp = new_comp }
    for _, v in ipairs(schema) do
      create_subcomponents(new_comp, comp_struct, v)
    end
    return comp_struct
  end

  return new_comp
end

function RenderData:remove_component(component)
  for i, c in ipairs(self.components) do
    if c == component then
      table.remove(self.components, i)
      return true
    end
  end

  return false
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
  for _, c in ipairs(self.components) do
    c:clear()
  end
end

---@param line_idx integer
---@param lines string[]
---@param hl_data HlData[]
---@param component RenderComponent
---@return integer
local function process_component(line_idx, lines, hl_data, component)
  if #component.components > 0 then
    for _, c in ipairs(component.components) do
      line_idx = process_component(line_idx, lines, hl_data, c)
    end

    return line_idx
  else
    for _, line in ipairs(component.lines) do
      table.insert(lines, line)
    end

    for _, hl in ipairs(component.hl) do
      table.insert(hl_data, {
          group = hl.group,
          line_idx = hl.line_idx + line_idx,
          first = hl.first,
          last = hl.last
        })
    end
    component.height = #component.lines

    if component.height > 0 then
      component.lstart = line_idx
      component.lend = line_idx + component.height
    else
      component.lstart = line_idx
      component.lend = line_idx
    end

    return component.lend
  end
end

---Render the given render data to the given buffer.
---@param bufid integer
---@param data RenderData
function M.render(bufid, data)
  if not a.nvim_buf_is_loaded(bufid) then return end

  local was_modifiable = a.nvim_buf_get_option(bufid, "modifiable")
  a.nvim_buf_set_option(bufid, "modifiable", true)

  local lines, hl_data
  local line_idx = 0
  if #data.components > 0 then
    lines = {}
    hl_data = {}
    for _, c in ipairs(data.components) do
      line_idx = process_component(line_idx, lines, hl_data, c)
    end
  else
    lines = data.lines
    hl_data = data.hl
  end

  a.nvim_buf_set_lines(bufid, 0, -1, false, lines)
  a.nvim_buf_clear_namespace(bufid, data.namespace, 0, -1)
  for _, hl in ipairs(hl_data) do
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
  if not config.get_config().file_panel.use_icons then return " " end
  if not web_devicons then
    local ok
    ok, web_devicons = pcall(require, 'nvim-web-devicons')
    if not ok then
      config.get_config().file_panel.use_icons = false
      utils.warn("nvim-web-devicons is required to use file icons! "
        .. "Set `use_icons = false` in your config to not see this message.")
      return " "
    end
  end

  local icon, hl = web_devicons.get_icon(name, ext)

  if icon then
    if hl then
      render_data:add_hl(hl, line_idx, offset, offset + string.len(icon) + 1)
    end
    return icon .. " "
  end

  return ""
end

M.RenderComponent = RenderComponent
M.RenderData = RenderData
return M
