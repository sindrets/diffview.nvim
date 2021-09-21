local utils = require("diffview.utils")
local renderer = require("diffview.renderer")

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
local function render_files(comp, files)
  local show_tree = true

  local line_idx = 0
  if not show_tree then
    for _, file in ipairs(files) do
      render_file(comp, file, 0, line_idx, true)
      line_idx = line_idx + 1
    end
    return
  end

  local tree = FileTree()
  tree:add_file_entries(files)

  local tree_items = tree:list()

  for _, node in ipairs(tree_items) do
    local depth = node.depth
    local is_file = not node:has_children()

    if not is_file then
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
---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()

  ---@type RenderComponent
  local comp = panel.components.path.comp
  local line_idx = 0
  local s = utils.path_shorten(vim.fn.fnamemodify(panel.git_root, ":~"), panel.width - 6)
  comp:add_hl("DiffviewFilePanelRootPath", line_idx, 0, #s)
  comp:add_line(s)

  comp = panel.components.working.title.comp
  line_idx = 0
  s = "Changes"
  comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
  local change_count = "(" .. #panel.files.working .. ")"
  comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
  s = s .. " " .. change_count
  comp:add_line(s)

  render_files(panel.components.working.files.comp, panel.files.working)

  if #panel.files.staged > 0 then
    comp = panel.components.staged.title.comp
    line_idx = 0
    comp:add_line("")
    line_idx = line_idx + 1
    s = "Staged changes"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    change_count = "(" .. #panel.files.staged .. ")"
    comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
    s = s .. " " .. change_count
    comp:add_line(s)

    render_files(panel.components.staged.files.comp, panel.files.staged)
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    local extra_info = utils.tbl_concat({ panel.rev_pretty_name }, panel.path_args or {})

    comp = panel.components.info.title.comp
    line_idx = 0
    comp:add_line("")
    line_idx = line_idx + 1

    s = "Showing changes for:"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    comp:add_line(s)

    comp = panel.components.info.entries.comp
    line_idx = 0
    for _, arg in ipairs(extra_info) do
      local relpath = utils.path_relative(arg, panel.git_root)
      if relpath == "" then
        relpath = "."
      end
      s = utils.path_shorten(relpath, panel.width - 5)
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      comp:add_line(s)
      line_idx = line_idx + 1
    end
  end
end
