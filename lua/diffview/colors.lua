local api = vim.api
local M = {}

---@param name string Syntax group name.
---@param attr string Attribute name.
---@param trans boolean Translate the syntax group (follows links).
function M.get_hl_attr(name, attr, trans)
  local id = api.nvim_get_hl_id_by_name(name)
  if id and trans then
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

---@param group_name string Syntax group name.
---@param trans boolean Translate the syntax group (follows links). True by default.
function M.get_fg(group_name, trans)
  if type(trans) ~= "boolean" then trans = true end
  return M.get_hl_attr(group_name, "fg", trans)
end

---@param group_name string Syntax group name.
---@param trans boolean Translate the syntax group (follows links). True by default.
function M.get_bg(group_name, trans)
  if type(trans) ~= "boolean" then trans = true end
  return M.get_hl_attr(group_name, "bg", trans)
end

---@param group_name string Syntax group name.
---@param trans boolean Translate the syntax group (follows links). True by default.
function M.get_gui(group_name, trans)
  if type(trans) ~= "boolean" then trans = true end
  local hls = {}
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
    if M.get_hl_attr(group_name, attr, trans) == "1" then
      table.insert(hls, attr)
    end
  end

  if #hls > 0 then
    return table.concat(hls, ",")
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
    FilePanelTitle = { fg = M.get_fg("Directory") or colors.blue, gui = "bold" },
    FilePanelCounter = { fg = M.get_fg("Identifier") or colors.purple, gui = "bold" },
    FilePanelFileName = { fg = M.get_fg("Normal") or colors.white },
    Dim1 = { fg = M.get_fg("Comment") or colors.white },
    Primary = { fg = M.get_fg("Identifier") or "Purple" },
    Secondary = { fg = M.get_fg("Constant") or "Orange" },
  }
end

M.hl_links = {
  Normal = "Normal",
  NonText = "NonText",
  CursorLine = "CursorLine",
  VertSplit = "VertSplit",
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
  local fg = M.get_fg("DiffDelete", false) or "NONE"
  local bg = M.get_bg("DiffDelete", false) or "NONE"
  local gui = M.get_gui("DiffDelete", false) or "NONE"
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
