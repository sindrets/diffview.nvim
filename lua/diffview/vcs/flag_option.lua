local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@alias FlagOption.CompletionWrapper fun(parent: FHOptionPanel): fun(ctx: CmdLineContext): string[]

---@class FlagOption
---@field flag_name string
---@field keymap string
---@field desc string
---@field key string
---@field expect_list boolean
---@field prompt_label string
---@field prompt_fmt string
---@field value_fmt string
---@field display_fmt string
---@field select? string[]
---@field completion? string|FlagOption.CompletionWrapper
local FlagOption = oop.create_class("FlagOption")

---@class FlagOption.init.Opt
---@field flag_name string
---@field keymap string
---@field desc string
---@field key string
---@field expect_list boolean
---@field prompt_label string
---@field prompt_fmt string
---@field value_fmt string
---@field display_fmt string
---@field select? string[]
---@field completion? string|FlagOption.CompletionWrapper
---@field transform function
---@field prepare_values function
---@field render_prompt function
---@field render_value function
---@field render_display function
---@field render_default function

---@param keymap string
---@param flag_name string
---@param desc string
---@param opt FlagOption.init.Opt
function FlagOption:init(keymap, flag_name, desc, opt)
  opt = opt or {}

  self.keymap = keymap
  self.flag_name = flag_name
  self.desc = desc
  self.key = opt.key or utils.str_match(flag_name, {
    "^%-%-?([^=]+)=?",
    "^%+%+?([^=]+)=?",
  }):gsub("%-", "_")
  self.select = opt.select
  self.completion = opt.completion
  self.expect_list = utils.sate(opt.expect_list, false)
  self.prompt_label = opt.prompt_label or ""
  self.prompt_fmt = opt.prompt_fmt or "${label}${flag_name}"
  self.value_fmt = opt.value_fmt or "${flag_name}${value}"
  self.display_fmt = opt.display_fmt or "${values}"
  self.transform = opt.transform or self.transform
  self.render_prompt = opt.render_prompt or self.render_prompt
  self.render_value = opt.render_value or self.render_value
  self.render_display = opt.render_display or self.render_display
  self.render_default = opt.render_default or self.render_default
end

---@param values any|any[]
---@return string[]
function FlagOption:prepare_values(values)
  if values == nil then
    return {}
  elseif type(values) ~= "table" then
    return { tostring(values) }
  else
    return vim.tbl_map(tostring, values)
  end
end

---Transform the values given by the user.
---@param values any|any[]
function FlagOption:transform(values)
  return utils.tbl_fmap(self:prepare_values(values), function(v)
    v = utils.str_match(v, { "^" .. vim.pesc(self.flag_name) .. "(.*)", ".*" })
    if v == "" then return nil end
    return v
  end)
end

function FlagOption:render_prompt()
  return utils.str_template(self.prompt_fmt, {
    label = self.prompt_label and self.prompt_label .. " " or "",
    flag_name = self.flag_name .. " ",
  }):sub(1, -2)
end

---Render a single option value
---@param value string
function FlagOption:render_value(value)
  value = value:gsub("\\", "\\\\")
  return utils.str_template(self.value_fmt, {
    flag_name = self.flag_name,
    value = utils.str_quote(value, { only_if_whitespace = true }),
  })
end

---Render the displayed text for the panel.
---@param values any|any[]
---@return boolean empty
---@return string rendered_text
function FlagOption:render_display(values)
  values = self:prepare_values(values)
  if #values == 0 or (#values == 1 and values[1] == "") then
    return true, self.flag_name
  end

  local quoted = table.concat(vim.tbl_map(function(v)
    return self:render_value(v)
  end, values), " ")

  return false, utils.str_template(self.display_fmt, {
    flag_name = self.flag_name,
    values = quoted,
  })
end

---Render the default text for |input()|.
---@param values any|any[]
function FlagOption:render_default(values)
  values = self:prepare_values(values)

  local ret = vim.tbl_map(function(v)
    return self:render_value(v)
  end, values)

  if #ret > 0 then
    ret[1] = ret[1]:match("^" .. vim.pesc(self.flag_name) .. "(.*)") or ret[1]
  end

  return table.concat(ret, " ")
end

M.FlagOption = FlagOption
return M
