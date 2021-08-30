local oop = require("diffview.oop")
local utils = require("diffview.utils")
local config = require("diffview.config")
local a = vim.api
local M = {}
local web_devicons
local uid_counter = 0

---@class HlData
---@field group string
---@field line_idx integer
---@field first integer 0 based, inclusive
---@field last integer Exclusive

---@class RenderComponent
---@field name string
---@field parent RenderComponent
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field lstart integer Inclusive
---@field lend integer Exclusive
---@field height integer
---@field context any
local RenderComponent = oop.Object
RenderComponent = oop.create_class("RenderComponent")

---RenderComponent constructor.
---@return RenderComponent
function RenderComponent:init(name)
  self.name = name
  self.lines = {}
  self.hl = {}
  self.components = {}
  self.lstart = -1
  self.lend = -1
  self.height = 0
end

local function create_subcomponents(parent, comp_struct, schema)
  for i, v in ipairs(schema) do
    v.name = v.name or RenderComponent.next_uid()
    local sub_comp = parent:create_component()
    sub_comp.name = v.name
    sub_comp.context = v.context
    sub_comp.parent = parent
    comp_struct[i] = {
      _name = v.name,
      comp = sub_comp,
    }
    comp_struct[v.name] = comp_struct[i]
    if #v > 0 then
      create_subcomponents(sub_comp, comp_struct[i], v)
    end
  end
end

function RenderComponent.next_uid()
  local uid = "comp_" .. uid_counter
  uid_counter = uid_counter + 1
  return uid
end

---Create and add a new component.
---@param schema any
---@return RenderComponent|any
function RenderComponent:create_component(schema)
  local comp_struct
  local new_comp = RenderComponent(schema and schema.name or RenderComponent.next_uid())
  table.insert(self.components, new_comp)

  if schema then
    new_comp.context = schema.context
    comp_struct = { _name = new_comp.name, comp = new_comp }
    create_subcomponents(new_comp, comp_struct, schema)
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
    last = last,
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

function RenderComponent:get_comp_on_line(line)
  line = line - 1

  local function recurse(child)
    if line >= child.lstart and line < child.lend then
      -- print(child.name, line, child.lstart, child.lend)
      if #child.components > 0 then
        for _, v in ipairs(child.components) do
          local target = recurse(v)
          if target then
            return target
          end
        end
      else
        return child
      end
    end
  end

  return recurse(self)
end

---@class RenderData
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field namespace integer
local RenderData = oop.Object
RenderData = oop.create_class("RenderData")

---RenderData constructor.
---@return RenderData
function RenderData:init(ns_name)
  self.lines = {}
  self.hl = {}
  self.components = {}
  self.namespace = a.nvim_create_namespace(ns_name)
end

---Create and add a new component.
---@param schema any
---@return RenderComponent|any
function RenderData:create_component(schema)
  local comp_struct
  local new_comp = RenderComponent(schema and schema.name or RenderComponent.next_uid())
  table.insert(self.components, new_comp)

  if schema then
    new_comp.context = schema.context
    comp_struct = { _name = new_comp.name, comp = new_comp }
    create_subcomponents(new_comp, comp_struct, schema)
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
    last = last,
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
    component.lstart = line_idx
    for _, c in ipairs(component.components) do
      line_idx = process_component(line_idx, lines, hl_data, c)
    end

    component.lend = line_idx
    component.height = component.lend - component.lstart
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
        last = hl.last,
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
  if not a.nvim_buf_is_loaded(bufid) then
    return
  end

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
  ["!"] = "DiffviewStatusIgnored",
}

function M.get_git_hl(status)
  return git_status_hl_map[status]
end

function M.get_file_icon(name, ext, render_data, line_idx, offset)
  if not config.get_config().use_icons then
    return " "
  end
  if not web_devicons then
    local ok
    ok, web_devicons = pcall(require, "nvim-web-devicons")
    if not ok then
      config.get_config().use_icons = false
      utils.warn(
        "nvim-web-devicons is required to use file icons! "
          .. "Set `use_icons = false` in your config to not see this message."
      )
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
