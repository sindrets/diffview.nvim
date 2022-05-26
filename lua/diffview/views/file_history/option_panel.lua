local config = require("diffview.config")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local EventEmitter = require("diffview.events").EventEmitter
local api = vim.api
local M = {}

---@class FHOptionPanel : Panel
---@field parent FileHistoryPanel
---@field emitter EventEmitter
---@field render_data RenderData
---@field option_state LogOptions
---@field components CompStruct
local FHOptionPanel = oop.create_class("FHOptionPanel", Panel)

FHOptionPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "VertSplit:DiffviewVertSplit",
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

FHOptionPanel.flags = {
  switches = {
    { "-f", "--follow", "Follow renames (only for single file)", key = "follow" },
    { "-a", "--all", "Include all refs", key = "all" },
    { "-m", "--merges", "List only merge commits", key = "merges" },
    { "-n", "--no-merges", "List no merge commits", key = "no_merges" },
    { "-r", "--reverse", "List commits in reverse order", key = "reverse" },
  },
  options = {
    { "=n", "--max-count=", "Limit number of commits", key = "max_count" },
    { "=a", "--author=", "List only commits from a given author", key = "author" },
    { "=g", "--grep=", "Filter commit messages", key = "grep" },
  },
}

for _, list in pairs(FHOptionPanel.flags) do
  for _, option in ipairs(list) do
    list[option.key] = option
  end
end

---FHOptionPanel constructor.
---@param parent FileHistoryPanel
---@return FHOptionPanel
function FHOptionPanel:init(parent)
  FHOptionPanel:super().init(self, {
    config = {
      position = "bottom",
    },
    bufname = "DiffviewFHOptionPanel",
  })
  self.parent = parent
  self.emitter = EventEmitter()

  self.emitter:on("set_option", function(option_name)
    local log_options = self.parent.log_options
    if FHOptionPanel.flags.switches[option_name] then
      self.parent.log_options[option_name] = not self.parent.log_options[option_name]
    elseif FHOptionPanel.flags.options[option_name] then
      local o = FHOptionPanel.flags.options[option_name]
      local new_value = utils.input(o[2], log_options[option_name])
      if new_value ~= "__INPUT_CANCELLED__" then
        if new_value == "" then
          new_value = nil
        end
        log_options[option_name] = new_value
      end
    end
    self:render()
    self:redraw()
  end)

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })

  self:on_autocmd("WinClosed", {
    callback = function()
      if not vim.deep_equal(self.option_state, self.parent.log_options) then
        vim.schedule(function ()
          self.option_state = nil
          self.winid = nil
          self.parent:update_entries(function(_, _)
            if not self.parent:cur_file() then
              self.parent.parent:next_item()
            end
          end)
        end)
      end
    end,
  })
end

---@Override
function FHOptionPanel:open()
  FHOptionPanel:super().open(self)
  self.option_state = utils.tbl_deep_clone(self.parent.log_options)
end

function FHOptionPanel:setup_buffer()
  local conf = config.get_config()
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for lhs, mapping in pairs(conf.keymaps.option_panel) do
    if type(lhs) == "number" then
      local opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = self.bufid })
      vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
    else
      vim.keymap.set("n", lhs, mapping, default_opt)
    end
  end

  for group, _ in pairs(FHOptionPanel.flags) do
    for option_name, v in pairs(FHOptionPanel.flags[group]) do
      vim.keymap.set(
        "n",
        v[1],
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
  for _, option in ipairs(FHOptionPanel.flags.switches) do
    table.insert(switch_schema, { name = "switch", context = { option.key, option } })
  end
  for _, option in ipairs(FHOptionPanel.flags.options) do
    table.insert(option_schema, { name = "option", context = { option.key, option } })
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
---@return LogEntry|FileEntry|nil
function FHOptionPanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  local comp = self.components.comp:get_comp_on_line(line)
  if comp and (comp.name == "switch" or comp.name == "option") then
    return comp.context
  end
end

function FHOptionPanel:render()
  require("diffview.views.file_history.render").fh_option_panel(self)
end

M.FHOptionPanel = FHOptionPanel
return M
