local oop = require("diffview.oop")
local utils = require("diffview.utils")
local config = require("diffview.config")
local api = vim.api

local M = {}
local web_devicons
local uid_counter = 0

---Duration of the last redraw in ms.
M.last_draw_time = 0

---@class HlData
---@field group string
---@field line_idx integer
---@field first integer 0 indexed, inclusive
---@field last integer Exclusive

---@class CompStruct : { [integer|string]: CompStruct }
---@field _name string
---@field comp RenderComponent

---@class CompSchema : { [integer]: CompSchema }
---@field name? string
---@field context? table

---@class RenderComponent : Object
---@field name string
---@field context? table
---@field parent RenderComponent
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field lstart integer 0 indexed, Inclusive
---@field lend integer Exclusive
---@field height integer
---@field leaf boolean
---@field data_root RenderData
local RenderComponent = oop.create_class("RenderComponent")

---RenderComponent constructor.
---@return RenderComponent
function RenderComponent:init(name)
  self.name = name or RenderComponent.next_uid()
  self.lines = {}
  self.hl = {}
  self.components = {}
  self.lstart = -1
  self.lend = -1
  self.height = 0
  self.leaf = false
end

---@param parent RenderComponent
---@param comp_struct CompStruct
---@param schema CompSchema
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
    else
      sub_comp.leaf = true
    end
  end
end

function RenderComponent.next_uid()
  local uid = "comp_" .. uid_counter
  uid_counter = uid_counter + 1
  return uid
end

---Create a new compoenent
---@param schema? CompSchema
---@return RenderComponent, CompStruct
function RenderComponent.create_static_component(schema)
  local comp_struct
  ---@diagnostic disable-next-line: need-check-nil
  local new_comp = RenderComponent(schema and schema.name or nil)

  if schema then
    new_comp.context = schema.context
    comp_struct = { _name = new_comp.name, comp = new_comp }
    create_subcomponents(new_comp, comp_struct, schema)
  end

  return new_comp, comp_struct
end

---Create and add a new component.
---@param schema? CompSchema
---@return RenderComponent|CompStruct
function RenderComponent:create_component(schema)
  local new_comp, comp_struct = RenderComponent.create_static_component(schema)
  new_comp.data_root = self.data_root
  self:add_component(new_comp)

  if comp_struct then
    return comp_struct
  end

  return new_comp
end

---@param component RenderComponent
function RenderComponent:add_component(component)
  component.parent = self
  self.components[#self.components + 1] = component
end

---@param component RenderComponent
function RenderComponent:remove_component(component)
  for i, c in ipairs(self.components) do
    if c == component then
      table.remove(self.components, i)
      return true
    end
  end

  return false
end

---@param line string
function RenderComponent:add_line(line)
  self.lines[#self.lines + 1] = line
end

---@param group string
---@param line_idx integer
---@param first integer
---@param last integer
function RenderComponent:add_hl(group, line_idx, first, last)
  self.hl[#self.hl + 1] = {
    group = group,
    line_idx = line_idx,
    first = first,
    last = last,
  }
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

function RenderComponent:destroy()
  self.lines = nil
  self.hl = nil
  self.parent = nil
  self.context = nil
  self.data_root = nil
  for _, c in ipairs(self.components) do
    c:destroy()
  end
  self.components = nil
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

---@param callback function(comp: RenderComponent, i: integer, parent: RenderComponent)
function RenderComponent:some(callback)
  for i, child in ipairs(self.components) do
    if callback(child, i, self) then
      return
    end
  end
end

function RenderComponent:deep_some(callback)
  local function wrap(comp, i, parent)
    if callback(comp, i, parent) then
      return true
    else
      return comp:some(wrap)
    end
  end
  self:some(wrap)
end

function RenderComponent:leaves()
  local leaves = {}
  self:deep_some(function(comp)
    if #comp.components == 0 then
      leaves[#leaves + 1] = comp
    end
    return false
  end)

  return leaves
end

function RenderComponent:pretty_print()
  local keys = { "name", "lstart", "lend" }

  local function recurse(depth, comp)
    local outer_padding = string.rep(" ", depth * 2)
    print(outer_padding .. "{")

    local inner_padding = outer_padding .. "  "
    for _, k in ipairs(keys) do
      print(string.format("%s%s = %s,", inner_padding, k, vim.inspect(comp[k])))
    end
    if #comp.lines > 0 then
      print(string.format("%slines = {", inner_padding))
      for _, line in ipairs(comp.lines) do
        print(string.format("%s  %s,", inner_padding, vim.inspect(line)))
      end
      print(string.format("%s},", inner_padding))
    end
    for _, child in ipairs(comp.components) do
      recurse(depth + 1, child)
    end

    print(outer_padding .. "},")
  end

  recurse(0, self)
end

---@class RenderData : Object
---@field lines string[]
---@field hl HlData[]
---@field components RenderComponent[]
---@field namespace integer
local RenderData = oop.create_class("RenderData")

---RenderData constructor.
---@return RenderData
function RenderData:init(ns_name)
  self.lines = {}
  self.hl = {}
  self.components = {}
  self.namespace = api.nvim_create_namespace(ns_name)
end

---Create and add a new component.
---@param schema table
---@return RenderComponent|CompStruct
function RenderData:create_component(schema)
  local comp_struct
  local new_comp = RenderComponent(schema and schema.name or nil)
  new_comp.data_root = self
  self:add_component(new_comp)

  if schema then
    new_comp.context = schema.context
    comp_struct = { _name = new_comp.name, comp = new_comp }
    create_subcomponents(new_comp, comp_struct, schema)
    return comp_struct
  end

  return new_comp
end

---@param component RenderComponent
function RenderData:add_component(component)
  self.components[#self.components + 1] = component
end

---@param component RenderComponent
function RenderData:remove_component(component)
  for i, c in ipairs(self.components) do
    if c == component then
      table.remove(self.components, i)
      return true
    end
  end

  return false
end

---@param group string
---@param line_idx integer
---@param first integer
---@param last integer
function RenderData:add_hl(group, line_idx, first, last)
  self.hl[#self.hl + 1] = {
    group = group,
    line_idx = line_idx,
    first = first,
    last = last,
  }
end

function RenderData:clear()
  self.lines = {}
  self.hl = {}
  for _, c in ipairs(self.components) do
    c:clear()
  end
end

function RenderData:destroy()
  self.lines = nil
  self.hl = nil
  for _, c in ipairs(self.components) do
    c:destroy()
  end
  self.components = {}
end

function M.destroy_comp_struct(schema)
  schema.comp = nil
  for k, v in pairs(schema) do
    if type(v) == "table" then
      M.destroy_comp_struct(v)
      schema[k] = nil
    end
  end
end

---Create a function to enable easily contraining the cursor to a given list of
---components.
---@param components RenderComponent[]
function M.create_cursor_constraint(components)
  local stack = utils.vec_slice(components, 1)
  utils.merge_sort(stack, function(a, b)
    return a.lstart <= b.lstart
  end)

  ---Given a cursor delta or target: returns the next valid line index inside a
  ---contraining component. When the cursor is trying to move out of a
  ---constraint, the next component is determined by the direction the cursor is
  ---moving.
  ---@param winid_or_opt number|{from: number, to: number}
  ---@param delta number The amount of change from the current cursor positon.
  ---Not needed if the first argument is a table.
  ---@return number
  return function(winid_or_opt, delta)
    local line_from, line_to
    if type(winid_or_opt) == "number" then
      local cursor = api.nvim_win_get_cursor(winid_or_opt)
      line_from, line_to = cursor[1] - 1, cursor[1] - 1 + delta
    else
      line_from, line_to = winid_or_opt.from - 1, winid_or_opt.to - 1
    end

    local min, max = math.min(line_from, line_to), math.max(line_from, line_to)
    local nearest_dist, dist, target = math.huge, nil, {}
    local top, bot
    local fstack = {}

    for _, comp in ipairs(stack) do
      if comp.height > 0 then
        fstack[#fstack + 1] = comp
        if min <= comp.lend and max >= comp.lstart then
          if not top then
            top = { idx = #fstack, comp = comp }
            bot = top
          else
            bot = { idx = #fstack, comp = comp }
          end
        end

        dist = math.min(math.abs(line_to - comp.lstart), math.abs(line_to - comp.lend))
        if dist < nearest_dist then
          nearest_dist = dist
          target = { idx = #fstack, comp = comp }
        end
      end
    end

    if not top and target.comp then
      return utils.clamp(line_to + 1, target.comp.lstart + 1, target.comp.lend)
    elseif top then
      if line_to < line_from then
        -- moving up
        if line_to < top.comp.lstart and top.idx > 1 then
          target = { idx = top.idx - 1, comp = fstack[top.idx - 1] }
        else
          target = top
        end
        return utils.clamp(line_to + 1, target.comp.lstart + 1, target.comp.lend)
      else
        -- moving down
        if line_to >= bot.comp.lend and bot.idx < #fstack then
          target = { idx = bot.idx + 1, comp = fstack[bot.idx + 1] }
        else
          target = bot
        end
        return utils.clamp(line_to + 1, target.comp.lstart + 1, target.comp.lend)
      end
    end

    return line_from
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
      lines[#lines + 1] = line
    end

    component.hl.offset = line_idx
    hl_data[#hl_data + 1] = component.hl
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
  if not api.nvim_buf_is_loaded(bufid) then
    return
  end

  local last = vim.loop.hrtime()
  local was_modifiable = api.nvim_buf_get_option(bufid, "modifiable")
  api.nvim_buf_set_option(bufid, "modifiable", true)

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
    hl_data = { data.hl }
  end

  api.nvim_buf_set_lines(bufid, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(bufid, data.namespace, 0, -1)
  for _, t in ipairs(hl_data) do
    for _, hl in ipairs(t) do
      api.nvim_buf_add_highlight(
        bufid,
        data.namespace,
        hl.group,
        hl.line_idx + (t.offset or 0),
        hl.first,
        hl.last
      )
    end
  end

  api.nvim_buf_set_option(bufid, "modifiable", was_modifiable)
  M.last_draw_time = (vim.loop.hrtime() - last) / 1000000
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

local icon_cache = {}

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
          .. "Set `use_icons = false` in your config to stop seeing this message."
      )
      return " "
    end
  end

  local icon, hl
  local icon_key = (name or "") .. "|&|" .. (ext or "")
  if icon_cache[icon_key] then
    icon, hl = unpack(icon_cache[icon_key])
  else
    icon, hl = web_devicons.get_icon(name, ext, { default = true })
    icon_cache[icon_key] = { icon, hl }
  end

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
