local PerfTimer = require("diffview.perf").PerfTimer
local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local fmt = string.format
local logger = DiffviewGlobal.logger
local perf = PerfTimer("[FileHistoryPanel] Render internal")
local pl = utils.path

local cache = setmetatable({}, { __mode = "k" })

local formatters = {
  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  status = function(comp, entry, _)
    if entry.status then
      comp:add_text(entry.status, hl.get_git_hl(entry.status))
    else
      comp:add_text("-", "DiffviewNonText")
    end
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  files = function(comp, entry, params)
    if entry.single_file then return end

    local s_num_files = tostring(params.max_num_files)

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

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  hash = function(comp, entry, _)
    if entry.commit.hash then comp:add_text(" " .. entry.commit.hash:sub(1, 8), "DiffviewHash") end
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  stats = function(comp, entry, params)
    if params.max_len_stats == -1 then return end

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
    comp:add_text(string.rep(" ", params.max_len_stats - (#adds[1] + #dels[1])))
    comp:add_text(unpack(dels))
    comp:add_text(" |", "DiffviewNonText")
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  reflog = function(comp, entry, _)
    local reflog_selector = (entry.commit --[[@as GitCommit ]]).reflog_selector
    if reflog_selector then
      comp:add_text((" %s"):format(reflog_selector), "DiffviewReflogSelector")
    end
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  ref = function(comp, entry, _)
    if entry.commit.ref_names then
      comp:add_text((" (%s)"):format(entry.commit.ref_names), "DiffviewReference")
    end
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  subject = function(comp, entry, params)
    local subject = utils.str_trunc(entry.commit.subject, 72)
    if subject == "" then subject = "[empty message]" end
    comp:add_text(
      " " .. subject,
      params.panel.cur_item[1] == entry and "DiffviewFilePanelSelected"
        or "DiffviewFilePanelFileName"
    )
  end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  author = function(comp, entry, _) comp:add_text(" " .. entry.commit.author) end,

  ---@type fun(comp:RenderComponent, entry:LogEntry, params:table)
  date = function(comp, entry, _)
    -- 3 months
    local date = (
      os.difftime(os.time(), entry.commit.time) > 60 * 60 * 24 * 30 * 3 and entry.commit.iso_date
      or entry.commit.rel_date
    )
    comp:add_text(" " .. date, "DiffviewFilePanelPath")
  end,
}

---@param comp RenderComponent
---@param files FileEntry[]
local function render_files(comp, files)
  for i, file in ipairs(files) do
    comp:add_text(i == #files and "└   " or "│   ", "DiffviewNonText")

    if file:is_null_entry() then
      comp:add_text(
        "No diff",
        file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName"
      )
    else
      if file.status then
        comp:add_text(file.status .. " ", hl.get_git_hl(file.status))
      else
        comp:add_text("-" .. " ", "DiffviewNonText")
      end

      local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
      comp:add_text(icon, icon_hl)

      if #file.parent_path > 0 then
        comp:add_text(file.parent_path .. "/", "DiffviewFilePanelPath")
      end

      comp:add_text(
        file.basename,
        file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName"
      )

      if file.stats then
        comp:add_text(" " .. file.stats.additions, "DiffviewFilePanelInsertions")
        comp:add_text(", ")
        comp:add_text(tostring(file.stats.deletions), "DiffviewFilePanelDeletions")
      end
    end

    comp:ln()
  end

  perf:lap("files")
end

---@param panel FileHistoryPanel
---@param parent CompStruct RenderComponent struct
---@param entries LogEntry[]
---@param updating boolean
local function render_entries(panel, parent, entries, updating)
  local c = config.get_config()
  local max_num_files = -1
  local max_len_stats = -1

  for _, entry in ipairs(entries) do
    if #entry.files > max_num_files then max_num_files = #entry.files end

    if entry.stats then
      local adds = tostring(entry.stats.additions)
      local dels = tostring(entry.stats.deletions)
      local l = 7
      local w = l - (#adds + #dels)
      if w < 1 then l = (#adds + #dels) - ((#adds + #dels) % 2) + 2 end
      max_len_stats = l > max_len_stats and l or max_len_stats
    end
  end

  for i, entry in ipairs(entries) do
    if i > #parent or (updating and i > 128) then break end

    local entry_struct = parent[i]
    local comp = entry_struct.commit.comp

    if not entry.single_file then
      comp:add_text(
        (entry.folded and c.signs.fold_closed or c.signs.fold_open) .. " ",
        "CursorLineNr"
      )
    end

    for format in c.file_history_panel.commit_format do
      local fn = formatters[format]
      if fn then
        fn(comp, entry, { max_len_stats, max_num_files, panel })
      else
        logger:warn("[format] Unsopported commit format: " .. format)
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
      and pl:truncate(pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"), panel:infer_width() - 6)
    or pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~")
  c.args = table.concat(panel.log_options.single_file.path_args, " ")
end

return {
  commit_formatters = formatters,

  ---@param panel FileHistoryPanel
  file_history_panel = function(panel)
    if not panel.render_data then return end

    perf:reset()
    panel.render_data:clear()

    if not cache[panel] then prepare_panel_cache(panel) end

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

    if panel.updating then comp:add_text(" (Updating...)", "DiffviewDim1") end

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
    if not panel.render_data then return end

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
  clear_cache = function(panel) cache[panel] = nil end,
}
