local Panel = require("diffview.ui.panel").Panel
local get_user_config = require("diffview.config").get_config
local oop = require("diffview.oop")

---@class HelpPanel : Panel
---@field keymap_name string
---@field lines string[]
---@field keys string[]
local HelpPanel = oop.create_class("HelpPanel", Panel)

HelpPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  wrap = false,
  breakindent = true,
  cursorbind = true,
})

HelpPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  buftype = "nowrite",
})

HelpPanel.default_type = "float"

---@class HelpPanelSpec
---@field config PanelConfig
---@field name string

---@param keymap_name string
---@param opt HelpPanelSpec
function HelpPanel:init(keymap_name, opt)
  HelpPanel:super().init(self, {
    bufname = opt.name,
    config = opt.config or get_user_config().help_panel.win_config,
  })

  self.keymap_name = keymap_name

  local keymaps = get_user_config().keymaps
  local maps = keymaps[self.keymap_name]
  local keys = {}
  for k, _ in pairs(keymaps[self.keymap_name]) do
    table.insert(keys, k)
  end
  table.sort(keys)
  self.keys = keys

  local lines = { "" }
  local max_width = 0

  for _, lhs in pairs(keys) do
    local mapping = maps[lhs]
    if type(lhs) == "number" then
      mapping = mapping[3]
      lhs = mapping[2]
    else
      if type(mapping) ~= "function" then
        mapping = mapping[2]
      end
    end
    local txt = string.format("%14s -> %s", lhs, mapping)

    if #txt > max_width then
      max_width = #txt
    end
    table.insert(lines, txt)
  end
  local height = #lines + 1
  local width = max_width + 1

  local title_line = "Actions for current panel <cr> for apply"
  title_line = string.rep(" ", math.floor(width * 0.5 - #title_line * 0.5) - 1) .. title_line
  table.insert(lines, 1, title_line)

  self.default_config_float.height = height
  self.default_config_float.width = width
  local viewport_width = vim.o.columns
  local viewport_height = vim.o.lines
  self.default_config_float.col = math.floor(viewport_width * 0.5 - width * 0.5)
  self.default_config_float.row = math.floor(viewport_height * 0.5 - height * 0.5)
  self.lines = lines

  self:on_autocmd("BufWinEnter", {
    callback = function()
      vim.bo[self.bufid].bufhidden = "wipe"
    end,
  })
end

function HelpPanel:apply_cmd()
  local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local cmd = self.keys[row-2]
  if cmd ~= nil then
    local keymap_entry = get_user_config().keymaps[self.keymap_name][cmd]
    if type(keymap_entry) == "function" then
        keymap_entry()
    else
        keymap_entry[1]()
    end
    self.destroy(self)
  end
end

function HelpPanel:init_buffer()
  HelpPanel:super().init_buffer(self)
  local conf = get_user_config().keymaps
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }

  for lhs, mapping in pairs(conf.help_panel) do
    if type(mapping) ~= "function" then
      default_opt.desc = mapping[2]
      mapping = mapping[1]
    end
    vim.keymap.set("n", lhs, mapping, default_opt)
  end
  vim.keymap.set("n", "<cr>", function()
    self.apply_cmd(self)
  end, default_opt)
end

function HelpPanel:update_components() end

function HelpPanel:render()
  self.render_data:clear()

  self.render_data.lines = self.lines
end

return HelpPanel
