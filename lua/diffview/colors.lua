local api = vim.api
local M = {}

---@param name string Syntax group name.
---@param attr string Attribute name.
---@param no_trans? boolean Don't translate the syntax group (follow links).
function M.get_hl_attr(name, attr, no_trans)
  local id = api.nvim_get_hl_id_by_name(name)
  if id and not no_trans then
    id = vim.fn.synIDtrans(id)
  end
  if not id then
    return
  end

  local value = vim.fn.synIDattr(id, attr)
  if not value or value == "" then
    return
  end

  return value
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
function M.get_fg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) == "table" then
    local v
    for _, group in ipairs(groups) do
      v = M.get_hl_attr(group, "fg", no_trans)
      if v then return v end
    end
    return
  end

  return M.get_hl_attr(groups, "fg", no_trans)
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
function M.get_bg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) == "table" then
    local v
    for _, group in ipairs(groups) do
      v = M.get_hl_attr(group, "bg", no_trans)
      if v then return v end
    end
    return
  end

  return M.get_hl_attr(groups, "bg", no_trans)
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
function M.get_gui(groups, no_trans)
  no_trans = not not no_trans
  if type(groups) ~= "table" then groups = { groups } end

  local hls
  for _, group in ipairs(groups) do
    hls = {}
    local attributes = {
      "bold",
      "italic",
      "reverse",
      "standout",
      "underline",
      "undercurl",
      "strikethrough"
    }

    for _, attr in ipairs(attributes) do
      if M.get_hl_attr(group, attr, no_trans) == "1" then
        table.insert(hls, attr)
      end
    end

    if #hls > 0 then
      return table.concat(hls, ",")
    end
  end
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
    FilePanelTitle = { fg = M.get_fg("Label") or colors.blue, gui = "bold" },
    FilePanelCounter = { fg = M.get_fg("Identifier") or colors.purple, gui = "bold" },
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
  FilePanelPath = "Comment",
  FilePanelInsertions = "diffAdded",
  FilePanelDeletions = "diffRemoved",
  FolderName = "Directory",
  FolderSign = "PreProc",
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
}

function M.update_diff_hl()
  local fg = M.get_fg("DiffDelete", true) or "NONE"
  local bg = M.get_bg("DiffDelete", true) or "NONE"
  local gui = M.get_gui("DiffDelete", true) or "NONE"
  vim.cmd(string.format("hi! DiffviewDiffAddAsDelete guifg=%s guibg=%s gui=%s", fg, bg, gui))
  vim.cmd("hi def link DiffviewDiffDelete Comment")
end

function M.setup()
  M.update_diff_hl()

  for name, v in pairs(M.get_hl_groups()) do
    local fg = v.fg and " guifg=" .. v.fg or ""
    local bg = v.bg and " guibg=" .. v.bg or ""
    local gui = v.gui and " gui=" .. v.gui or ""
    vim.cmd("hi def Diffview" .. name .. fg .. bg .. gui)
  end

  for from, to in pairs(M.hl_links) do
    vim.cmd("hi def link Diffview" .. from .. " " .. to)
  end
end

return M
