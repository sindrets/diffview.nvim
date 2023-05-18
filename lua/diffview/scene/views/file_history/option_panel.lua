local lazy = require("diffview.lazy")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel") ---@type Panel|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local panel_renderer = lazy.require("diffview.scene.views.file_history.render") ---@module "diffview.scene.views.file_history.render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@class FHOptionPanel : Panel
---@field parent FileHistoryPanel
---@field emitter EventEmitter
---@field render_data RenderData
---@field option_state LogOptions
---@field components CompStruct
local FHOptionPanel = oop.create_class("FHOptionPanel", Panel.__get())

FHOptionPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  },
})

FHOptionPanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "DiffviewFileHistory",
  bufhidden = "hide",
}

---FHOptionPanel constructor.
---@param parent FileHistoryPanel
function FHOptionPanel:init(parent)
  self:super({
    ---@type PanelSplitSpec
    config = {
      position = "bottom",
      height = #parent.adapter.flags.switches + #parent.adapter.flags.options + 4,
    },
    bufname = "DiffviewFHOptionPanel",
  })
  self.parent = parent
  self.emitter = EventEmitter()
  self.flags = parent.adapter.flags

  ---@param option_name string
  self.emitter:on("set_option", function(_, option_name)
    local log_options = self.parent:get_log_options()
    local cur_value = log_options[option_name]

    if self.flags.switches[option_name] then
      self:_set_option(option_name, not cur_value)
      self:render()
      self:redraw()

    elseif self.flags.options[option_name] then
      local o = self.flags.options[option_name]

      if o.select then
        vim.ui.select(o.select, {
          prompt = o:render_prompt(),
          format_item = function(item)
            return item == "" and "<unset>" or item
          end,
        }, function(choice)
          if choice then
            self:_set_option(option_name, choice)
          end

          self:render()
          self:redraw()
        end)

      else
        local completion = type(o.completion) == "function" and o.completion(self) or o.completion

        utils.input(o:render_prompt(), {
          default = o:render_default(cur_value),
          completion = type(completion) == "function" and function(_, cmd_line, cur_pos)
            ---@cast completion fun(ctx: CmdLineContext): string[]
            local ctx = arg_parser.scan(cmd_line, { cur_pos = cur_pos })
            return arg_parser.process_candidates(completion(ctx), ctx, true)
          end or completion,
          callback = function(response)
            if response ~= "__INPUT_CANCELLED__" then
              local values = response == nil and { "" } or arg_parser.scan(response).args

              if o.transform then
                values = o:transform(values)
              end

              if not o.expect_list then
                ---@cast values string
                values = values[1]
              end

              self:_set_option(option_name, values)
            end

            self:render()
            self:redraw()
          end,
        })
      end
    end
  end)

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })

  self:on_autocmd("WinClosed", {
    callback = function()
      if not vim.deep_equal(self.option_state, self.parent:get_log_options()) then
        vim.schedule(function ()
          self.option_state = nil
          self.winid = nil
          self.parent:update_entries(function(_, status)
            if status >= JobStatus.ERROR then
              return
            end
            if not self.parent:cur_file() then
              self.parent.parent:next_item()
            end
          end)
        end)
      end
    end,
  })
end

---@private
function FHOptionPanel:_set_option(name, value)
  self.parent.log_options.single_file[name] = value
  self.parent.log_options.multi_file[name] = value
end

---@override
function FHOptionPanel:open()
  FHOptionPanel.super_class.open(self)
  self.option_state = utils.tbl_deep_clone(self.parent:get_log_options())

  api.nvim_win_call(self.winid, function()
    vim.cmd("norm! zb")
  end)
end

function FHOptionPanel:setup_buffer()
  local conf = config.get_config()
  local default_opt = { silent = true, buffer = self.bufid }
  for _, mapping in ipairs(conf.keymaps.option_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end

  for _, group in pairs(self.flags) do
    ---@cast group FlagOption[]
    for option_name, v in pairs(group) do
      vim.keymap.set(
        "n",
        v.keymap,
        function()
          self.emitter:emit("set_option", option_name)
        end,
        { silent = true, buffer = self.bufid }
      )
    end
  end
end

function FHOptionPanel:update_components()
  local switch_schema = {}
  local option_schema = {}
  for _, option in ipairs(self.flags.switches) do
    table.insert(switch_schema, { name = "switch", context = { option = option, }, })
  end
  for _, option in ipairs(self.flags.options) do
    table.insert(option_schema, { name = "option", context = { option = option }, })
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    {
      name = "switches",
      { name = "title" },
      { name = "items", unpack(switch_schema) },
    },
    {
      name = "options",
      { name = "title" },
      { name = "items", unpack(option_schema) },
    },
  })
end

---Get the file entry under the cursor.
---@return FlagOption?
function FHOptionPanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  local comp = self.components.comp:get_comp_on_line(line)
  if comp and (comp.name == "switch" or comp.name == "option") then
    return comp.context.option
  end
end

function FHOptionPanel:render()
  panel_renderer.fh_option_panel(self)
end

M.FHOptionPanel = FHOptionPanel
return M
