local Panel = require("diffview.ui.panel").Panel
local get_user_config = require("diffview.config").get_config
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api

local M = {}

---@class HelpPanel : Panel
---@field keymap_name string
---@field lines string[]
---@field maps table[]
local HelpPanel = oop.create_class("HelpPanel", Panel)

HelpPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  wrap = false,
  breakindent = true,
  signcolumn = "no",
})

HelpPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  buftype = "nofile",
})

HelpPanel.default_type = "float"

---@class HelpPanelSpec
---@field parent StandardView
---@field config PanelConfig
---@field name string

---@param parent StandardView
---@param keymap_name string
---@param opt HelpPanelSpec
function HelpPanel:init(parent, keymap_name, opt)
  opt = opt or {}
  HelpPanel:super().init(self, {
    bufname = opt.name,
    config = opt.config or get_user_config().help_panel.win_config,
  })

  self.parent = parent
  self.keymap_name = keymap_name
  self.lines = {}

  self:on_autocmd("BufWinEnter", {
    callback = function()
      vim.bo[self.bufid].bufhidden = "wipe"
    end,
  })

  self:on_autocmd("WinLeave", {
    callback = function()
      pcall(self.close, self)
    end,
  })

  parent.emitter:on("close", function(e)
    if self:is_focused() then
      pcall(self.close, self)
      e:stop_propagation()
    end
  end)
end

function HelpPanel:apply_cmd()
  local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local mapping = self.maps[row-2]
  local last_winid = vim.fn.win_getid(vim.fn.winnr("#"))

  if mapping then
    api.nvim_win_call(last_winid, function()
      api.nvim_feedkeys(utils.t(mapping[2]), "m", false)
    end)

    pcall(self.close, self)
  end
end

function HelpPanel:init_buffer()
  HelpPanel:super().init_buffer(self)
  local conf = get_user_config().keymaps
  local default_opt = { silent = true, nowait = true, buffer = self.bufid }

  for _, mapping in ipairs(conf.help_panel) do
    local map_opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], map_opt)
  end

  vim.keymap.set("n", "<cr>", function()
    self:apply_cmd()
  end, default_opt)
end

function HelpPanel:update_components()
  local keymaps = get_user_config().keymaps
  local maps = keymaps[self.keymap_name]

  if not maps then
    utils.err(("Unknown keymap group '%s'!"):format(self.keymap_name))
  else
    maps = vim.tbl_map(function(v)
      local desc = v[4] and v[4].desc

      if not desc then
        if type(v[3]) == "string" then
          desc = v[3]
        elseif type(v[3]) == "function" then
          local info = debug.getinfo(v[3], "S")
          desc = ("<Lua @ %s:%d>"):format(info.short_src, info.linedefined)
        end
      end

      return utils.vec_join(v, desc)
    end, maps)
    -- Sort mappings by description
    table.sort(maps, function(a, b)
      a, b = a[5], b[5]
      -- Ensure lua functions are sorted last
      if a:match("^<Lua") then a = "~" .. a end
      if b:match("^<Lua") then b = "~" .. b end
      return a < b
    end)

    local lines = { "" }
    local max_width = 0

    for _, mapping in ipairs(maps) do
      local txt = string.format("%14s -> %s", mapping[2], mapping[5])

      max_width = math.max(max_width, #txt)
      table.insert(lines, txt)
    end

    local height = #lines + 1
    local width = max_width + 2
    local title_line = ("Keymaps for '%s' — <cr> to use"):format(self.keymap_name)
    title_line = string.rep(" ", math.floor(width * 0.5 - #title_line * 0.5) - 1) .. title_line
    table.insert(lines, 1, title_line)

    self.maps = maps
    self.lines = lines

    self.config_producer = function()
      local c = vim.deepcopy(Panel.default_config_float)
      local viewport_width = vim.o.columns
      local viewport_height = vim.o.lines
      c.col = math.floor(viewport_width * 0.5 - width * 0.5)
      c.row = math.floor(viewport_height * 0.5 - height * 0.5)
      c.width = width
      c.height = height

      return c
    end
  end
end

function HelpPanel:render()
  self.render_data:clear()
  self.render_data.lines = utils.vec_slice(self.lines or {})
end

M.HelpPanel = HelpPanel
return M
