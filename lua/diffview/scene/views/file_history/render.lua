local utils = require("diffview.utils")
local config = require("diffview.config")
local renderer = require("diffview.renderer")
local logger = require("diffview.logger")
local PerfTimer = require("diffview.perf").PerfTimer

---@type PerfTimer
local perf = PerfTimer("[FileHistoryPanel] Render internal")

local cache = setmetatable({}, { __mode = "k" })

---@param comp RenderComponent
---@param files FileEntry[]
local function render_files(comp, files)
  local line_idx = 0

  for i, file in ipairs(files) do
    local s
    if i == #files then
      s = "└   "
    else
      s = "│   "
    end
    comp:add_hl("DiffviewNonText", line_idx, 0, #s)
    local offset

    if file.status then
      offset = #s
      comp:add_hl(renderer.get_git_hl(file.status), line_idx, offset, offset + 1)
      s = s .. file.status .. " "
    end

    offset = #s
    local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, offset)
    offset = offset + #icon
    if #file.parent_path > 0 then
      comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path + 1)
    end
    comp:add_hl(
      "DiffviewFilePanelFileName",
      line_idx,
      offset + #file.path - #file.basename,
      offset + #file.basename
    )
    s = s .. icon .. file.path

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

    comp:add_line(s)
    line_idx = line_idx + 1
  end

  perf:lap("files")
end

---@param parent CompStruct RenderComponent struct
---@param entries LogEntry[]
---@param updating boolean
local function render_entries(parent, entries, updating)
  local c = config.get_config()
  local max_num_files = -1
  local max_len_stats = 7

  for _, entry in ipairs(entries) do
    if #entry.files > max_num_files then
      max_num_files = #entry.files
    end

    if entry.stats then
      local adds = tostring(entry.stats.additions)
      local dels = tostring(entry.stats.deletions)
      local l = 7
      local w = l - (#adds + #dels)
      if w < 1 then
        l = (#adds + #dels) - ((#adds + #dels) % 2) + 2
      end
      max_len_stats = l > max_len_stats and l or max_len_stats
    end
  end

  for i, entry in ipairs(entries) do
    if i > #parent or (updating and i > 128) then
      break
    end

    local entry_struct = parent[i]
    local line_idx = 0
    local offset = 0
    local comp = entry_struct.commit.comp
    local s = ""

    if not entry.single_file then
      comp:add_hl("CursorLineNr", line_idx, 0, 3)
      s = (entry.folded and c.signs.fold_closed or c.signs.fold_open) .. " "
    end

    if entry.status then
      offset = #s
      comp:add_hl(renderer.get_git_hl(entry.status), line_idx, offset, offset + 1)
      s = s .. entry.status
    end

    if not entry.single_file then
      offset = #s
      local counter = " "
        .. utils.str_left_pad(tostring(#entry.files), #tostring(max_num_files))
        .. (" file%s"):format(#entry.files > 1 and "s" or " ")
      comp:add_hl("DiffviewFilePanelCounter", line_idx, offset, offset + #counter)
      s = s .. counter
    end

    if entry.stats then
      local adds = tostring(entry.stats.additions)
      local dels = tostring(entry.stats.deletions)
      local w = max_len_stats - (#adds + #dels)

      comp:add_hl("DiffviewNonText", line_idx, #s + 1, #s + 2)
      s = s .. " | "
      offset = #s
      comp:add_hl("DiffviewFilePanelInsertions", line_idx, offset, offset + #adds)
      comp:add_hl(
        "DiffviewFilePanelDeletions",
        line_idx,
        offset + #adds + w,
        offset + #adds + w + #dels
      )
      s = s .. adds .. string.rep(" ", w) .. dels .. " | "
      comp:add_hl("DiffviewNonText", line_idx, #s - 2, #s)
    end

    offset = #s
    if entry.commit.hash then
      local hash = entry.commit.hash:sub(1, 8)
      comp:add_hl("DiffviewSecondary", line_idx, offset, offset + #hash)
      s = s .. hash .. " "
    end

    offset = #s
    local subject = utils.str_shorten(entry.commit.subject, 72)
    if subject == "" then
      subject = "[empty message]"
    end
    comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #subject)
    s = s .. subject .. " "

    offset = #s
    if entry.commit then
      -- 3 months
      local date = (
          os.difftime(os.time(), entry.commit.time) > 60 * 60 * 24 * 30 * 3
            and entry.commit.iso_date
          or entry.commit.rel_date
        )
      local info = entry.commit.author .. ", " .. date
      comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #info)
      s = s .. info
    end

    comp:add_line(s)
    line_idx = line_idx + 1

    perf:lap("entry " .. entry.commit.hash:sub(1, 7))

    if not entry.single_file and not entry.folded then
      render_files(entry_struct.files.comp, entry.files)
    end
  end
end

---@param panel FileHistoryPanel
local function prepare_panel_cache(panel)
  local c = {}
  cache[panel] = c
  c.root_path = panel.state.form == "column"
      and utils.path:shorten(
        utils.path:vim_fnamemodify(panel.git_root, ":~"),
        panel:get_config().width - 6
      )
    or utils.path:vim_fnamemodify(panel.git_root, ":~")
  c.args = table.concat(panel.raw_args, " ")
end

return {
  ---@param panel FileHistoryPanel
  file_history_panel = function(panel)
    if not panel.render_data then
      return
    end

    perf:reset()
    panel.render_data:clear()
    if not cache[panel] then
      prepare_panel_cache(panel)
    end

    local comp = panel.components.header.comp
    local log_options = panel:get_log_options()
    local cached = cache[panel]
    local line_idx = 0
    local s

    -- root path
    comp:add_hl("DiffviewFilePanelRootPath", line_idx, 0, #cached.root_path)
    comp:add_line(cached.root_path)

    local offset
    if panel.single_file then
      line_idx = line_idx + 1
      if #panel.entries > 0 then
        local file = panel.entries[1].files[1]

        -- file path
        local icon = renderer.get_file_icon(file.basename, file.extension, comp, line_idx, 0)
        offset = #icon
        if #file.parent_path > 0 then
          comp:add_hl("DiffviewFilePanelPath", line_idx, offset, offset + #file.parent_path + 1)
        end
        comp:add_hl(
          "DiffviewFilePanelFileName",
          line_idx,
          offset + #file.parent_path + 1,
          offset + #file.basename
        )
        s = icon .. file.path
        comp:add_line(s)
      end
    elseif #cached.args > 0 then
      line_idx = line_idx + 1
      s = "Showing history for: "
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      offset = #s
      local paths = cached.args
      comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #paths)
      comp:add_line(s .. paths)
    end

    if log_options.rev_range and log_options.rev_range ~= "" then
      line_idx = line_idx + 1
      s = "Revision range: "
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      offset = #s
      s = s .. log_options.rev_range
      comp:add_hl("DiffviewFilePanelFileName", line_idx, offset, offset + #s)
      comp:add_line(s)
    end

    if panel.option_mapping then
      line_idx = line_idx + 1
      s = "Options: "
      comp:add_hl("DiffviewFilePanelPath", line_idx, 0, #s)
      offset = #s
      comp:add_hl("DiffviewFilePanelCounter", line_idx, offset, offset + #panel.option_mapping)
      comp:add_line(s .. panel.option_mapping)
    end

    -- title
    comp = panel.components.log.title.comp
    comp:add_line("")
    line_idx = 1
    s = "File History"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    local change_count = "(" .. #panel.entries .. ")"
    comp:add_hl("DiffviewFilePanelCounter", line_idx, #s + 1, #s + 1 + string.len(change_count))
    s = s .. " " .. change_count
    if panel.updating then
      offset = #s
      local status = " (Updating...)"
      comp:add_hl("DiffviewDim1", line_idx, offset, offset + #status)
      s = s .. status
    end
    comp:add_line(s)

    perf:lap("header")

    if #panel.entries > 0 then
      render_entries(panel.components.log.entries, panel.entries, panel.updating)
    end

    perf:time()
    logger.lvl(10).s_debug(perf)
  end,

  ---@param panel FHOptionPanel
  fh_option_panel = function(panel)
    if not panel.render_data then
      return
    end

    panel.render_data:clear()

    ---@type RenderComponent
    local comp = panel.components.switches.title.comp
    local line_idx = 0
    local offset
    local log_options = panel.parent:get_log_options()

    local s = "Switches"
    comp:add_hl("DiffviewFilePanelTitle", line_idx, 0, #s)
    comp:add_line(s)

    for _, item in ipairs(panel.components.switches.items) do
      ---@type RenderComponent
      comp = item.comp
      local option = comp.context[2]
      local enabled = log_options[comp.context[1]]

      s = " " .. option[1] .. " "
      comp:add_hl("DiffviewSecondary", 0, 0, #s)

      offset = #s
      comp:add_hl("DiffviewFilePanelFileName", 0, offset, offset + #option[3])
      s = s .. option[3] .. " ("

      offset = #s
      comp:add_hl(
        enabled and "DiffviewFilePanelCounter" or "DiffviewDim1",
        0,
        offset,
        offset + #option[2]
      )
      s = s .. option[2]

      offset = #s
      comp:add_hl("DiffviewFilePanelFileName", 0, offset, offset + 1)
      s = s .. ")"
      comp:add_line(s)
    end

    comp = panel.components.options.title.comp
    comp:add_line("")
    s = "Options"
    comp:add_hl("DiffviewFilePanelTitle", 1, 0, #s)
    comp:add_line(s)

    for _, item in ipairs(panel.components.options.items) do
      ---@type RenderComponent
      comp = item.comp
      ---@type FlagOption
      local option = comp.context[2]
      local value = log_options[comp.context[1]] or ""

      s = " " .. option[1] .. " "
      comp:add_hl("DiffviewSecondary", 0, 0, #s)

      offset = #s
      comp:add_hl("DiffviewFilePanelFileName", 0, offset, offset + #option[3])
      s = s .. option[3] .. " ("

      offset = #s
      local empty, display_value = option:render_value(value)
      comp:add_hl(
        not empty and "DiffviewFilePanelCounter" or "DiffviewDim1",
        0,
        offset,
        offset + #display_value
      )
      s = s .. display_value

      offset = #s
      comp:add_hl("DiffviewFilePanelFileName", 0, offset, offset + 1)
      s = s .. ")"
      comp:add_line(s)
    end
  end,
}
