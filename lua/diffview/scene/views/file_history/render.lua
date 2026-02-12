local PerfTimer = require("diffview.perf").PerfTimer
local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local fmt = string.format
local logger = DiffviewGlobal.logger
local perf = PerfTimer("[FileHistoryPanel] Render internal")
local pl = utils.path

local cache = setmetatable({}, { __mode = "k" })

local MAX_BAR_WIDTH = 20

---Render a stat bar (like git --stat) onto a component.
---@param comp RenderComponent
---@param additions integer
---@param deletions integer
local function render_stat_bar(comp, additions, deletions)
  local total = additions + deletions
  if total == 0 then return end

  local bar_width = math.min(total, MAX_BAR_WIDTH)
  local add_width = math.floor(additions / total * bar_width + 0.5)
  local del_width = bar_width - add_width

  comp:add_text(" | ", "DiffviewNonText")
  comp:add_text(tostring(total) .. " ", "DiffviewFilePanelCounter")

  if add_width > 0 then
    comp:add_text(string.rep("+", add_width), "DiffviewFilePanelInsertions")
  end
  if del_width > 0 then
    comp:add_text(string.rep("-", del_width), "DiffviewFilePanelDeletions")
  end
end

---Render file stats onto a component.
---@param comp RenderComponent
---@param stats GitStats
---@param stat_style string
local function render_file_stats(comp, stats, stat_style)
  local show_number = stat_style == "number" or stat_style == "both"
  local show_bar = stat_style == "bar" or stat_style == "both"

  if show_number then
    comp:add_text(" " .. stats.additions, "DiffviewFilePanelInsertions")
    comp:add_text(", ")
    comp:add_text(tostring(stats.deletions), "DiffviewFilePanelDeletions")
  end

  if show_bar and stats.additions and stats.deletions then
    render_stat_bar(comp, stats.additions, stats.deletions)
  end
end

---@param comp RenderComponent
---@param files FileEntry[]
local function render_files(comp, files)
  local stat_style = config.get_config().file_history_panel.stat_style or "number"

  for i, file in ipairs(files) do
    comp:add_text(i == #files and "└   " or "│   ", "DiffviewNonText")

    if file:is_null_entry() then
      comp:add_text(
        "No diff",
        file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName"
      )
    else
      if file.status then
        comp:add_text(hl.get_status_icon(file.status) .. " ", hl.get_git_hl(file.status))
      else
        comp:add_text("-" .. " ", "DiffviewNonText")
      end

      local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
      comp:add_text(icon, icon_hl)

      if #file.parent_path > 0 then
        comp:add_text(file.parent_path .. "/", "DiffviewFilePanelPath")
      end

      comp:add_text(file.basename, file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName")

      if file.stats then
        render_file_stats(comp, file.stats, stat_style)
      end
    end

    comp:ln()
  end

  perf:lap("files")
end

---@class FHRenderCtx
---@field conf DiffviewConfig
---@field panel FileHistoryPanel
---@field max_num_files integer
---@field max_len_stats integer

---Individual commit entry formatters, keyed by name.
---@type table<string, fun(comp: RenderComponent, entry: LogEntry, ctx: FHRenderCtx)>
local formatters = {
  status = function(comp, entry, _ctx)
    if entry.status then
      comp:add_text(hl.get_status_icon(entry.status), hl.get_git_hl(entry.status))
    else
      comp:add_text("-", "DiffviewNonText")
    end
  end,

  files = function(comp, entry, ctx)
    if entry.single_file then return end
    local s_num_files = tostring(ctx.max_num_files)

    if entry.nulled then
      comp:add_text(utils.str_center_pad("empty", #s_num_files + 7), "DiffviewFilePanelCounter")
    else
      comp:add_text(
        fmt(
          " %s file%s",
          utils.str_left_pad(tostring(#entry.files), #s_num_files),
          #entry.files > 1 and "s" or " "
        ),
        "DiffviewFilePanelCounter"
      )
    end
  end,

  stats = function(comp, entry, ctx)
    if ctx.max_len_stats == -1 then return end
    local adds = { "-", "DiffviewNonText" }
    local dels = { "-", "DiffviewNonText" }

    if entry.stats and entry.stats.additions then
      adds = { tostring(entry.stats.additions), "DiffviewFilePanelInsertions" }
    end

    if entry.stats and entry.stats.deletions then
      dels = { tostring(entry.stats.deletions), "DiffviewFilePanelDeletions" }
    end

    comp:add_text(" | ", "DiffviewNonText")
    comp:add_text(unpack(adds))
    comp:add_text(string.rep(" ", ctx.max_len_stats - (#adds[1] + #dels[1])))
    comp:add_text(unpack(dels))
    comp:add_text(" |", "DiffviewNonText")
  end,

  hash = function(comp, entry, _ctx)
    if entry.commit.hash then
      comp:add_text(" " .. entry.commit.hash:sub(1, 8), "DiffviewHash")
    end
  end,

  reflog = function(comp, entry, _ctx)
    if (entry.commit --[[@as GitCommit ]]).reflog_selector then
      comp:add_text((" %s"):format((entry.commit --[[@as GitCommit ]]).reflog_selector), "DiffviewReflogSelector")
    end
  end,

  ref = function(comp, entry, _ctx)
    if entry.commit.ref_names then
      comp:add_text((" (%s)"):format(entry.commit.ref_names), "DiffviewReference")
    end
  end,

  subject = function(comp, entry, ctx)
    local subject = utils.str_trunc(
      entry.commit.subject,
      ctx.conf.file_history_panel.commit_subject_max_length
    )

    if subject == "" then
      subject = "[empty message]"
    end

    local subject_hl
    if ctx.panel.cur_item[1] == entry then
      subject_hl = "DiffviewFilePanelSelected"
    elseif entry.has_remote_ref then
      subject_hl = "DiffviewCommitRemoteRef"
    else
      subject_hl = "DiffviewCommitLocalOnly"
    end

    comp:add_text(" " .. subject, subject_hl)
  end,

  author = function(comp, entry, _ctx)
    if entry.commit then
      comp:add_text(" " .. entry.commit.author, "DiffviewFilePanelPath")
    end
  end,

  date = function(comp, entry, ctx)
    if not entry.commit then return end
    local date_format = ctx.conf.file_history_panel.date_format
    local date
    if date_format == "relative" then
      date = entry.commit.rel_date
    elseif date_format == "iso" then
      date = entry.commit.iso_date
    else
      -- "auto": show relative for recent commits (< 3 months), ISO for older.
      date = (
        os.difftime(os.time(), entry.commit.time) > 60 * 60 * 24 * 30 * 3
          and entry.commit.iso_date
          or entry.commit.rel_date
      )
    end
    comp:add_text(", " .. date, "DiffviewFilePanelPath")
  end,
}

---@param panel FileHistoryPanel
---@param parent CompStruct RenderComponent struct
---@param entries LogEntry[]
---@param updating boolean
local function render_entries(panel, parent, entries, updating)
  local c = config.get_config()
  local commit_format = c.file_history_panel.commit_format
  local max_num_files = -1
  local max_len_stats = -1

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

  ---@type FHRenderCtx
  local ctx = {
    conf = c,
    panel = panel,
    max_num_files = max_num_files,
    max_len_stats = max_len_stats,
  }

  for i, entry in ipairs(entries) do
    if i > #parent or (updating and i > 128) then
      break
    end

    local entry_struct = parent[i]
    local comp = entry_struct.commit.comp

    if not entry.single_file then
      comp:add_text((entry.folded and c.signs.fold_closed or c.signs.fold_open) .. " ", "DiffviewFolderSign")
    end

    for _, part in ipairs(commit_format) do
      local formatter = formatters[part]
      if formatter then
        formatter(comp, entry, ctx)
      end
    end

    comp:ln()
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
      and pl:truncate(
        pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"),
        panel:infer_width() - 6
      )
    or pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~")
  c.args = table.concat(panel.log_options.single_file.path_args, " ")
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

    local conf = config.get_config()
    local comp = panel.components.header.comp
    local log_options = panel:get_log_options()
    local cached = cache[panel]

    -- root path
    comp:add_text(cached.root_path, "DiffviewFilePanelRootPath")
    comp:ln()

    if panel.single_file then
      if #panel.entries > 0 then
        local file = panel.entries[1].files[1]

        -- file path
        local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
        comp:add_text(icon, icon_hl)

        if #file.parent_path > 0 then
          comp:add_text(file.parent_path .. "/", "DiffviewFilePanelPath")
        end

        comp:add_text(file.basename, "DiffviewFilePanelFileName")
        comp:ln()
      end
    elseif #cached.args > 0 then
      comp:add_text("Showing history for: ", "DiffviewFilePanelPath")
      comp:add_text(cached.args, "DiffviewFilePanelFileName")
      comp:ln()
    end

    if log_options.rev_range and log_options.rev_range ~= "" then
      comp:add_text("Revision range: ", "DiffviewFilePanelPath")
      comp:add_text(log_options.rev_range, "DiffviewFilePanelFileName")
      comp:ln()
    end

    if panel.option_mapping then
      comp:add_text("Options: ", "DiffviewFilePanelPath")
      comp:add_text(panel.option_mapping, "DiffviewFilePanelCounter")
      comp:ln()
    end

    if conf.show_help_hints and panel.help_mapping then
      comp:add_text("Help: ", "DiffviewFilePanelPath")
      comp:add_text(panel.help_mapping, "DiffviewFilePanelCounter")
      comp:ln()
    end

    -- title
    comp = panel.components.log.title.comp
    comp:add_line()
    comp:add_text("File History ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.entries .. ")", "DiffviewFilePanelCounter")

    if panel.updating then
      comp:add_text(" (Updating...)", "DiffviewDim1")
    end

    comp:ln()
    perf:lap("header")

    if #panel.entries > 0 then
      render_entries(panel, panel.components.log.entries, panel.entries, panel.updating)
    end

    perf:time()
    logger:lvl(10):debug(perf)
  end,

  ---@param panel FHOptionPanel
  fh_option_panel = function(panel)
    if not panel.render_data then
      return
    end

    panel.render_data:clear()

    local comp = panel.components.switches.title.comp
    local log_options = panel.parent:get_log_options()

    comp:add_line("Switches", "DiffviewFilePanelTitle")

    for _, item in ipairs(panel.components.switches.items) do
      comp = item.comp
      local option = comp.context.option --[[@as FlagOption ]]
      local enabled = log_options[option.key] --[[@as boolean ]]

      comp:add_text(" " .. option.keymap .. " ", "DiffviewSecondary")
      comp:add_text(option.desc .. " (", "DiffviewFilePanelFileName")
      comp:add_text(option.flag_name, enabled and "DiffviewFilePanelCounter" or "DiffviewDim1")
      comp:add_text(")", "DiffviewFilePanelFileName")
      comp:ln()
    end

    comp = panel.components.options.title.comp
    comp:add_line()
    comp:add_line("Options", "DiffviewFilePanelTitle")

    for _, item in ipairs(panel.components.options.items) do
      comp = item.comp
      local option = comp.context.option --[[@as FlagOption ]]
      local value = log_options[option.key] or ""

      comp:add_text(" " .. option.keymap .. " ", "DiffviewSecondary")
      comp:add_text(option.desc .. " (", "DiffviewFilePanelFileName")

      local empty, display_value = option:render_display(value)
      comp:add_text(display_value, not empty and "DiffviewFilePanelCounter" or "DiffviewDim1")

      comp:add_text(")", "DiffviewFilePanelFileName")
      comp:ln()
    end
  end,
  clear_cache = function(panel)
    cache[panel] = nil
  end,
}
