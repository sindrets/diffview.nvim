local utils = require("diffview.utils")
local config = require("diffview.config")
local renderer = require("diffview.renderer")

---@param comp  RenderComponent
---@param show_path boolean
---@param depth integer|nil
local function render_file(comp, show_path, depth)
  ---@type table
  local file = comp.context
  local offset = 0

  comp:add_hl(renderer.get_git_hl(file.status), 0, 0, 1)
  local s = file.status .. " "
  if depth then
    s = s .. string.rep(" ", depth * 2 + 2)
  end

  offset = #s
  local icon = renderer.get_file_icon(file.basename, file.extension, comp, 0, offset)

  offset = offset + #icon
  comp:add_hl("DiffviewFilePanelFileName", 0, offset, offset + #file.basename)
  s = s .. icon .. file.basename

  if file.stats then
    offset = #s + 1
    comp:add_hl("DiffviewFilePanelInsertions", 0, offset, offset + string.len(file.stats.additions))
    offset = offset + string.len(file.stats.additions) + 2
    comp:add_hl("DiffviewFilePanelDeletions", 0, offset, offset + string.len(file.stats.deletions))
    s = s .. " " .. file.stats.additions .. ", " .. file.stats.deletions
  end

  if show_path then
    offset = #s + 1
    comp:add_hl("DiffviewFilePanelPath", 0, offset, offset + #file.parent_path)
    s = s .. " " .. file.parent_path
  end

  comp:add_line(s)
end

---@param comp RenderComponent
local function render_file_list(comp)
  for _, file_comp in ipairs(comp.components) do
    render_file(file_comp, true)
  end
end

---@param ctx DirData
---@param tree_options TreeOptions
---@return string
local function get_dir_status_text(ctx, tree_options)
  local folder_statuses = tree_options.folder_statuses
  if folder_statuses == "always" or (folder_statuses == "only_folded" and ctx.collapsed) then
    return ctx.status
  end
  return " "
end

---@param depth integer
---@param comp RenderComponent
local function render_file_tree_recurse(depth, comp)
  local conf = config.get_config()
  local offset, s

  if comp.name == "file" then
    render_file(comp, false, depth)
    return
  end
  if comp.name ~= "wrapper" then
    return
  end

  local dir = comp.components[1]
  ---@type table
  local ctx = dir.context

  dir:add_hl(renderer.get_git_hl(ctx.status), 0, 0, 1)
  s = get_dir_status_text(ctx, conf.file_panel.tree_options) .. " "

  s = s .. string.rep(" ", depth * 2)
  offset = #s

  local fold = ctx.collapsed and conf.signs.fold_closed or conf.signs.fold_open
  local icon = ""
  if conf.use_icons then
    icon = " " .. (ctx.collapsed and conf.icons.folder_closed or conf.icons.folder_open)
  end
  dir:add_hl("DiffviewNonText", 0, offset, offset + #fold)
  dir:add_hl("DiffviewFolderSign", 0, offset + #fold + 1, offset + #fold + 1 + #icon)
  s = string.format("%s%s%s ", s, fold, icon)

  offset = #s
  dir:add_hl("DiffviewFolderName", 0, offset, offset + #ctx.name)
  dir:add_line(s .. ctx.name)

  if not ctx.collapsed then
    for i = 2, #comp.components do
      render_file_tree_recurse(depth + 1, comp.components[i])
    end
  end
end

---@param comp RenderComponent
local function render_file_tree(comp)
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(0, c)
  end
end

---@param listing_style "list"|"tree"
---@param comp RenderComponent
local function render_files(listing_style, comp)
  if listing_style == "list" then
    return render_file_list(comp)
  end
  render_file_tree(comp)
end

---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local width = panel:get_width()
  if not width then
    local panel_config = panel:get_config()
    width = panel_config.width
  end

  ---@type RenderComponent
  local comp = panel.components.path.comp
  local line_idx = 0
  local s = utils.path:shorten(utils.path:vim_fnamemodify(panel.git_root, ":~"), width - 6)
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

  render_files(panel.listing_style, panel.components.working.files.comp)

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

    render_files(panel.listing_style, panel.components.staged.files.comp)
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    local extra_info = utils.vec_join({ panel.rev_pretty_name }, panel.path_args or {})

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
      local relpath = utils.path:relative(arg, panel.git_root)
      if relpath == "" then
        relpath = "."
      end
      s = utils.path:shorten(relpath, width - 5)
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      comp:add_line(s)
      line_idx = line_idx + 1
    end
  end
end
