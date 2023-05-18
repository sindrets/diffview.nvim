local Panel = require("diffview.ui.panel").Panel
local get_user_config = require("diffview.config").get_config
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api

local M = {}

---@class HelpPanel : Panel
---@field parent StandardView
---@field keymap_groups string[]
---@field state table
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
---@field config PanelConfig
---@field name string

---@param parent StandardView
---@param keymap_groups string[]
---@param opt HelpPanelSpec
function HelpPanel:init(parent, keymap_groups, opt)
  opt = opt or {}
  self:super({
    bufname = opt.name,
    config = opt.config or function()
      local c = vim.deepcopy(Panel.default_config_float)
      local viewport_width = vim.o.columns
      local viewport_height = vim.o.lines
      c.col = math.floor(viewport_width * 0.5 - self.state.width * 0.5)
      c.row = math.floor(viewport_height * 0.5 - self.state.height * 0.5)
      c.width = self.state.width
      c.height = self.state.height

      return c
    end,
  })

  self.parent = parent
  self.keymap_groups = keymap_groups
  self.lines = {}
  self.state = {
    width = 50,
    height = 4,
  }

  self:on_autocmd("BufWinEnter", {
    callback = function()
      vim.bo[self.bufid].bufhidden = "wipe"
    end,
  })

  self:on_autocmd("WinLeave", {
    callback = function()
      self:close()
    end,
  })

  parent.emitter:on("close", function(e)
    if self:is_focused() then
      self:close()
      e:stop_propagation()
    end
  end)
end

function HelpPanel:apply_cmd()
  local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local comp = self.components.comp:get_comp_on_line(row)

  if comp then
    local mapping = comp.context.mapping
    local last_winid = vim.fn.win_getid(vim.fn.winnr("#"))

    if mapping then
      api.nvim_win_call(last_winid, function()
        api.nvim_feedkeys(utils.t(mapping[2]), "m", false)
      end)

      self:close()
    end
  end
end

function HelpPanel:init_buffer()
  HelpPanel.super_class.init_buffer(self)
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
  local width = 50
  local height = 0
  local sections = { name = "sections" }

  for _, group in ipairs(self.keymap_groups) do
    local maps = keymaps[group]

    if not maps then
      utils.err(("help_panel :: Unknown keymap group '%s'!"):format(group))
    else
      maps = utils.tbl_fmap(maps, function(v)
        if v[1] ~= "n" then return nil end
        local desc = v[4] and v[4].desc

        if not desc then
          if type(v[3]) == "string" then
            desc = v[3]
          elseif type(v[3]) == "function" then
            local info = debug.getinfo(v[3], "S")
            desc = ("<Lua @ %s:%d>"):format(info.short_src, info.linedefined)
          end
        end

        local ret = utils.tbl_clone(v)
        ret[5] = desc

        return ret
      end)

      if #maps == 0 then goto continue end

      -- Sort mappings by description
      table.sort(maps, function(a, b)
        a, b = a[5], b[5]
        -- Ensure lua functions are sorted last
        if a:match("^<Lua") then a = "~" .. a end
        if b:match("^<Lua") then b = "~" .. b end
        return a < b
      end)

      local items = { name = "items" }
      local section_schema = {
        name = "section",
        {
          name = "section_heading",
          context = {
            label = group:upper():gsub("_", "-")
          },
        },
        items,
      }

      for _, mapping in ipairs(maps) do
        local desc = mapping[5]

        if desc ~= "diffview_ignore" then
          width = math.max(width, 14 + 4 + #mapping[5] + 2)
          table.insert(items, {
            name = "item",
            context = {
              label_lhs = ("%14s"):format(mapping[2]),
              label_rhs = desc,
              mapping = mapping,
            },
          })
        end
      end

      height = height + #items + 3
      table.insert(sections, section_schema)
    end

    ::continue::
  end

  self.state.width = width
  self.state.height = height + 1
  self.components = self.render_data:create_component({
    { name = "heading" },
    sections,
  })
end

function HelpPanel:render()
  self.render_data:clear()

  local s = ""

  -- Heading
  local comp = self.components.heading.comp
  s = "Keymap Overview — <CR> To Use"
  s = string.rep(" ", math.floor(self.state.width * 0.5 - vim.str_utfindex(s) * 0.5)) .. s
  comp:add_line(s, "DiffviewFilePanelTitle")

  for _, section in ipairs(self.components.sections) do
    ---@cast section CompStruct

    -- Section heading
    comp = section.section_heading.comp
    comp:add_line()
    s = string.rep(" ", math.floor(self.state.width * 0.5 - #comp.context.label * 0.5)) .. comp.context.label
    comp:add_line(s, "Statement")
    comp:add_line(("%14s    CALLBACK"):format("KEYS"), "DiffviewFilePanelCounter")

    for _, item in ipairs(section.items) do
      ---@cast item CompStruct
      comp = item.comp
      comp:add_text(comp.context.label_lhs, "DiffviewSecondary")
      comp:add_text(" -> ", "DiffviewNonText")
      comp:add_text(comp.context.label_rhs)
      comp:ln()
    end
  end
end

M.HelpPanel = HelpPanel
return M
