local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local web_devicons
local icon_cache = {}

local M = {}

---@alias hl.HiValue<T> T|"NONE"

---@class hl.HiSpec
---@field fg         hl.HiValue<string>
---@field bg         hl.HiValue<string>
---@field sp         hl.HiValue<string>
---@field style      hl.HiValue<string>
---@field ctermfg    hl.HiValue<integer>
---@field ctermbg    hl.HiValue<integer>
---@field cterm      hl.HiValue<string>
---@field blend      hl.HiValue<integer>
---@field default    hl.HiValue<boolean> Only set values if the hl group is cleared.
---@field link       string|-1
---@field explicit   boolean All undefined fields will be cleared from the hl group.

---@class hl.HiLinkSpec
---@field force boolean
---@field default boolean
---@field clear boolean

---@class hl.HlData
---@field link string|integer
---@field fg integer Foreground color integer
---@field bg integer Background color integer
---@field sp integer Special color integer
---@field x_fg string Foreground color hex string
---@field x_bg string Bakground color hex string
---@field x_sp string Special color hex string
---@field bold boolean
---@field italic boolean
---@field underline boolean
---@field underlineline boolean
---@field undercurl boolean
---@field underdash boolean
---@field underdot boolean
---@field strikethrough boolean
---@field standout boolean
---@field reverse boolean
---@field blend integer
---@field default boolean

---@alias hl.HlAttrValue integer|boolean

local HAS_NVIM_0_8 = vim.fn.has("nvim-0.8") == 1
local HAS_NVIM_0_9 = vim.fn.has("nvim-0.9") == 1

---@enum HlAttribute
M.HlAttribute = {
  fg = 1,
  bg = 2,
  sp = 3,
  x_fg = 4,
  x_bg = 5,
  x_sp = 6,
  bold = 7,
  italic = 8,
  underline = 9,
  underlineline = 10,
  undercurl = 11,
  underdash = 12,
  underdot = 13,
  strikethrough = 14,
  standout = 15,
  reverse = 16,
  blend = 17,
}

local style_attrs = {
  "bold",
  "italic",
  "underline",
  "underlineline",
  "undercurl",
  "underdash",
  "underdot",
  "strikethrough",
  "standout",
  "reverse",
}

-- NOTE: Some atrtibutes have been renamed in v0.8.0
if HAS_NVIM_0_8 then
  M.HlAttribute.underdashed = M.HlAttribute.underdash
  M.HlAttribute.underdash = nil

  M.HlAttribute.underdotted = M.HlAttribute.underdot
  M.HlAttribute.underdot = nil

  M.HlAttribute.underdouble = M.HlAttribute.underlineline
  M.HlAttribute.underlineline = nil

  style_attrs = {
    "bold",
    "italic",
    "underline",
    "underdouble",
    "undercurl",
    "underdashed",
    "underdotted",
    "strikethrough",
    "standout",
    "reverse",
  }
end

utils.add_reverse_lookup(M.HlAttribute)
utils.add_reverse_lookup(style_attrs)
local hlattr = M.HlAttribute

---@param name string Syntax group name.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return hl.HlData?
function M.get_hl(name, no_trans)
  local hl

  if no_trans then
    if HAS_NVIM_0_9 then
      hl = api.nvim_get_hl(0, { name = name, link = true })
    else
      hl = api.nvim__get_hl_defs(0)[name]
    end
  else
    local id = api.nvim_get_hl_id_by_name(name)

    if id then
      if HAS_NVIM_0_9 then
        hl = api.nvim_get_hl(0, { id = id, link = false })
      else
        hl = api.nvim_get_hl_by_id(id, true)
      end
    end
  end

  if hl then
    if not HAS_NVIM_0_9 then
      -- Handle renames
      if hl.foreground then hl.fg = hl.foreground; hl.foreground = nil end
      if hl.background then hl.bg = hl.background; hl.background = nil end
      if hl.special then hl.sp = hl.special; hl.special = nil end
    end

    if hl.fg then hl.x_fg = string.format("#%06x", hl.fg) end
    if hl.bg then hl.x_bg = string.format("#%06x", hl.bg) end
    if hl.sp then hl.x_sp = string.format("#%06x", hl.sp) end

    return hl
  end
end

---@param name string Syntax group name.
---@param attr HlAttribute|string Attribute kind.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return hl.HlAttrValue?
function M.get_hl_attr(name, attr, no_trans)
  local hl = M.get_hl(name, no_trans)

  if type(attr) == "string" then attr = hlattr[attr] end

  if not (hl and attr) then return end

  return hl[hlattr[attr]]
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_fg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local v = M.get_hl_attr(group, hlattr.x_fg, no_trans) --[[@as string? ]]

    if v then return v end
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_bg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local v = M.get_hl_attr(group, hlattr.x_bg, no_trans) --[[@as string? ]]

    if v then return v end
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_style(groups, no_trans)
  no_trans = not not no_trans
  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local hl = M.get_hl(group, no_trans)

    if hl then
      local res = {}

      for _, attr in ipairs(style_attrs) do
        if hl[attr] then table.insert(res, attr)
        end

        if #res > 0 then
          return table.concat(res, ",")
        end
      end
    end
  end
end

---@param spec hl.HiSpec
---@return hl.HlData
function M.hi_spec_to_def_map(spec)
  ---@type hl.HlData
  local res = {}
  local fields = { "fg", "bg", "sp", "ctermfg", "ctermbg", "default", "link" }

  for _, field in ipairs(fields) do
    res[field] = spec[field]
  end

  if spec.style then
    local spec_attrs = utils.add_reverse_lookup(vim.split(spec.style, ","))

    for _, attr in ipairs(style_attrs) do
      res[attr] = spec_attrs[attr] ~= nil
    end
  end

  return res
end

---@param groups string|string[] Syntax group name or a list of group names.
---@param opt hl.HiSpec
function M.hi(groups, opt)
  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local def_spec

    if opt.explicit then
      def_spec = M.hi_spec_to_def_map(opt)
    else
      def_spec = M.hi_spec_to_def_map(
        vim.tbl_extend("force", M.get_hl(group, true) or {}, opt)
      )
    end

    for k, v in pairs(def_spec) do
      if v == "NONE" then
        def_spec[k] = nil
      end
    end

    if not HAS_NVIM_0_9 and def_spec.link then
      -- Pre 0.9 `nvim_set_hl()` could not set other attributes in combination
      -- with `link`. Furthermore, setting non-link attributes would clear the
      -- link, but this does *not* happen if you set the other attributes first
      -- (???). However, if the value of `link` is `-1`, the group will be
      -- cleared regardless (?????).
      local link = def_spec.link
      def_spec.link = nil

      if not def_spec.default then
        api.nvim_set_hl(0, group, def_spec)
      end

      if link ~= -1 then
        api.nvim_set_hl(0, group, { link = link, default = def_spec.default })
      end
    else
      api.nvim_set_hl(0, group, def_spec)
    end
  end
end

---@param from string|string[] Syntax group name or a list of group names.
---@param to? string Syntax group name. (default: `"NONE"`)
---@param opt? hl.HiLinkSpec
function M.hi_link(from, to, opt)
  if to and tostring(to):upper() == "NONE" then
    ---@diagnostic disable-next-line: cast-local-type
    to = -1
  end

  opt = vim.tbl_extend("keep", opt or {}, {
    force = true,
  }) --[[@as hl.HiLinkSpec ]]

  if type(from) ~= "table" then from = { from } end

  for _, f in ipairs(from) do
    if opt.clear then
      if not HAS_NVIM_0_9 then
        -- Pre 0.9 `nvim_set_hl()` did not clear other attributes when `link` was set.
        api.nvim_set_hl(0, f, {})
      end

      api.nvim_set_hl(0, f, { default = opt.default, link = to })

    else
      -- When `clear` is not set; use our `hi()` function such that other
      -- attributes are not affected.
      M.hi(f, { default = opt.default, link = to })
    end
  end
end

---Clear highlighting for a given syntax group, or all groups if no group is
---given.
---@param groups? string|string[]
function M.hi_clear(groups)
  if not groups then
    vim.cmd("hi clear")
    return
  end

  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, g in ipairs(groups) do
    api.nvim_set_hl(0, g, {})
  end
end

function M.get_file_icon(name, ext, render_data, line_idx, offset)
  if not config.get_config().use_icons then return "" end

  if not web_devicons then
    local ok
    ok, web_devicons = pcall(require, "nvim-web-devicons")

    if not ok then
      config.get_config().use_icons = false
      utils.warn(
        "nvim-web-devicons is required to use file icons! "
          .. "Set `use_icons = false` in your config to stop seeing this message."
      )

      return ""
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
    if hl and render_data then
      render_data:add_hl(hl, line_idx, offset, offset + string.len(icon) + 1)
    end

    return icon .. " ", hl
  end

  return ""
end

local git_status_hl_map = {
  ["A"] = "DiffviewStatusAdded",
  ["?"] = "DiffviewStatusUntracked",
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

function M.get_colors()
  return {
    white = M.get_fg("Normal") or "White",
    red = M.get_fg("Keyword") or "Red",
    green = M.get_fg("Character") or "Green",
    yellow = M.get_fg("PreProc") or "Yellow",
    blue = M.get_fg("Include") or "Blue",
    purple = M.get_fg("Define") or "Purple",
    cyan = M.get_fg("Conditional") or "Cyan",
    dark_red = M.get_fg("Keyword") or "DarkRed",
    orange = M.get_fg("Number") or "Orange",
  }
end

function M.get_hl_groups()
  local colors = M.get_colors()

  return {
    FilePanelTitle = { fg = M.get_fg("Label") or colors.blue, style = "bold" },
    FilePanelCounter = { fg = M.get_fg("Identifier") or colors.purple, style = "bold" },
    FilePanelFileName = { fg = M.get_fg("Normal") or colors.white },
    Dim1 = { fg = M.get_fg("Comment") or colors.white },
    Primary = { fg = M.get_fg("Function") or "Purple" },
    Secondary = { fg = M.get_fg("String") or "Orange" },
  }
end

M.hl_links = {
  Normal = "Normal",
  NonText = "NonText",
  CursorLine = "CursorLine",
  WinSeparator = "WinSeparator",
  SignColumn = "Normal",
  StatusLine = "StatusLine",
  StatusLineNC = "StatusLineNC",
  EndOfBuffer = "EndOfBuffer",
  FilePanelRootPath = "DiffviewFilePanelTitle",
  FilePanelFileName = "Normal",
  FilePanelSelected = "Type",
  FilePanelPath = "Comment",
  FilePanelInsertions = "diffAdded",
  FilePanelDeletions = "diffRemoved",
  FilePanelConflicts = "DiagnosticSignWarn",
  FolderName = "Directory",
  FolderSign = "PreProc",
  Hash = "Identifier",
  Reference = "Function",
  ReflogSelector = "Special",
  StatusAdded = "diffAdded",
  StatusUntracked = "diffAdded",
  StatusModified = "diffChanged",
  StatusRenamed = "diffChanged",
  StatusCopied = "diffChanged",
  StatusTypeChange = "diffChanged",
  StatusUnmerged = "diffChanged",
  StatusUnknown = "diffRemoved",
  StatusDeleted = "diffRemoved",
  StatusBroken = "diffRemoved",
  StatusIgnored = "Comment",
  DiffAdd = "DiffAdd",
  DiffDelete = "DiffDelete",
  DiffChange = "DiffChange",
  DiffText = "DiffText",
}

function M.update_diff_hl()
  local fg = M.get_fg("DiffDelete", true) or "NONE"
  local bg = M.get_bg("DiffDelete", true) or "NONE"
  local style = M.get_style("DiffDelete", true) or "NONE"

  M.hi("DiffviewDiffAddAsDelete", { fg = fg, bg = bg, style = style })
  M.hi_link("DiffviewDiffDeleteDim", "Comment", { default = true })

  if config.get_config().enhanced_diff_hl then
    M.hi_link("DiffviewDiffDelete", "DiffviewDiffDeleteDim")
  end
end

function M.setup()
  for name, v in pairs(M.get_hl_groups()) do
    v = vim.tbl_extend("force", v, { default = true })
    M.hi("Diffview" .. name, v)
  end

  for from, to in pairs(M.hl_links) do
    M.hi_link("Diffview" .. from, to, { default = true })
  end

  M.update_diff_hl()
end

return M
