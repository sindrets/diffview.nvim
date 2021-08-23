local a = vim.api
local M = {}

function M.get_hl_attr(hl_group_name, attr)
  local id = a.nvim_get_hl_id_by_name(hl_group_name)
  if not id then
    return
  end

  local value = vim.fn.synIDattr(id, attr)
  if not value or value == "" then
    return
  end

  return value
end

function M.get_fg(hl_group_name)
  return M.get_hl_attr(hl_group_name, "fg")
end

function M.get_bg(hl_group_name)
  return M.get_hl_attr(hl_group_name, "bg")
end

function M.get_gui(hl_group_name)
  return M.get_hl_attr(hl_group_name, "gui")
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
  }
end

M.hl_links = {
  Normal = "Normal",
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
  StatusIgnored = "Comment"
}

function M.setup()
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
