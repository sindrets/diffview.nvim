local FileEntry = require("diffview.views.file_entry").FileEntry
local FileTree = require("diffview.views.file_tree.file_tree").FileTree
local renderer = require("diffview.renderer")

local M = {}

---@param comp RenderComponent
---@param file FileEntry
---@param depth number
---@param line_idx number
---@param show_path number
local function render_file(comp, file, depth, line_idx, show_path)
  comp:add_hl(renderer.get_git_hl(file.status), line_idx, 0, 1)
  local s = file.status .. " "
  local offset = 0

  local indent = "  "
  for _ = 1, depth do
    s = s .. indent
    offset = offset + #indent
  end

  local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, offset)
  offset = offset + #icon
  comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #file.basename)
  s = s .. icon .. file.basename

  if file.stats then
    offset = #s + 1
    comp:add_hl(
      "DiffviewFilePanelInsertions",
      line_idx,
      offset,
      offset + string.len(file.stats.additions)
    )
    offset = offset + string.len(file.stats.additions) + 2
    comp:add_hl(
      "DiffviewFilePanelDeletions",
      line_idx,
      offset,
      offset + string.len(file.stats.deletions)
    )
    s = s .. " " .. file.stats.additions .. ", " .. file.stats.deletions
  end

  if show_path then
    offset = #s + 1
    comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path)
    s = s .. " " .. file.parent_path
  end

  comp:add_line(s)
end

---@param comp RenderComponent
---@param dir FileEntry
local function render_directory(comp, dir, depth, line_idx)
  comp:add_hl(renderer.get_git_hl(dir.status), line_idx, 0, 1)
  local s = dir.status .. " "
  local offset = #s

  local indent = "  "
  for _ = 1, depth do
    s = s .. indent
    offset = offset + #indent
  end

  local icon = renderer.get_file_icon(dir.basename, dir.extension, comp, line_idx, offset)
  offset = offset + #icon
  comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #dir.path)
  s = s .. icon .. dir.path

  comp:add_line(s)
end

---@param comp RenderComponent
---@param files FileEntry[]
function M.render_file_tree(comp, files)
  local tree = FileTree()
  tree:add_file_entries(files)

  local tree_items = tree:list()
  local line_idx = 0

  for _, node in ipairs(tree_items) do
    local depth = node.depth

    if node:has_children() then
      local dir_name = node.name
      local dir = FileEntry({
        path = dir_name,
        status = " ",
        -- TODO: other properties
      })
      render_directory(comp, dir, depth, line_idx)
    else
      local file = node.data
      render_file(comp, file, depth, line_idx, false)
    end

    line_idx = line_idx + 1
  end
end

---@param comp RenderComponent
---@param files FileEntry[]
function M.render_file_list(comp, files)
  local line_idx = 0
  for _, file in ipairs(files) do
    render_file(comp, file, 0, line_idx, true)
    line_idx = line_idx + 1
  end
end

return M
