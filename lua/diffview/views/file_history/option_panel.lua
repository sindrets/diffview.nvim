local EventEmitter = require("diffview.events").EventEmitter
local JobStatus = require("diffview.git.utils").JobStatus
local Panel = require("diffview.ui.panel").Panel
local arg_parser = require("diffview.arg_parser")
local config = require("diffview.config")
local diffview = require("diffview")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local M = {}

---@class FHOptionPanel : Panel
---@field parent FileHistoryPanel
---@field emitter EventEmitter
---@field render_data RenderData
---@field option_state LogOptions
---@field components CompStruct
local FHOptionPanel = oop.create_class("FHOptionPanel", Panel)

FHOptionPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  },
})

FHOptionPanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "DiffviewFileHistory",
  bufhidden = "hide",
}

---@class FlagOption : string[]
---@field key string
---@field prompt_label string
---@field prompt_fmt string
---@field select string[]
---@field completion string|fun(panel: FHOptionPanel): function
---@field transform fun(values: string[]): any
---@field render_value fun(option: FlagOption, value: string|string[]): boolean, string
---@field render_default fun(options: FlagOption, value: string|string[]): string

FHOptionPanel.flags = {
  ---@type FlagOption[]
  switches = {
    { "-f", "--follow", "Follow renames (only for single file)" },
    { "-p", "--first-parent", "Follow only the first parent upon seeing a merge commit" },
    { "-s", "--show-pulls", "Show merge commits the first introduced a change to a branch" },
    { "-R", "--reflog", "Include all reachable objects mentioned by reflogs" },
    { "-a", "--all", "Include all refs" },
    { "-m", "--merges", "List only merge commits" },
    { "-n", "--no-merges", "List no merge commits" },
    { "-r", "--reverse", "List commits in reverse order" },
  },
  ---@type FlagOption[]
  options = {
    {
      "=r", "++rev-range=", "Show only commits in the specified revision range",
      ---@param panel FHOptionPanel
      completion = function(panel)
        return function(arg_lead, _, _)
          local view = panel.parent.parent
          return diffview.rev_completion(arg_lead, {
            accept_range = true,
            git_root = view.git_root,
            git_dir = view.git_dir,
          })
        end
      end,
    },
    { "=n", "--max-count=", "Limit the number of commits" },
    {
      "=L", "-L", "Trace line evolution",
      prompt_label = "(Accepts multiple values)",
      prompt_fmt = "${label} ",
      completion = function(_)
        return function(arg_lead, _, _)
          return diffview.line_trace_completion(arg_lead)
        end
      end,
      transform = function(values)
        return utils.tbl_fmap(values, function(v)
          v = utils.str_match(v, { "^-L(.*)", ".*" })

          if v == "" then
            return nil
          end

          return v
        end)
      end,
      ---@param self FlagOption
      ---@param value string|string[]
      render_value = function(self, value)
        if #value == 0 then
          -- Just render the flag name
          return true, self[2]
        end

        -- Render a string of quoted args
        return false, table.concat(vim.tbl_map(function(v)
          if not v:match("^-L") then
            -- Prepend the flag if it wasn't specified by the user.
            v = "-L" .. v
          end
          return utils.str_quote(v, { only_if_whitespace = true })
        end, value), " ")
      end,
      render_default = function(_, value)
        if #value == 0 then
          -- Just render the flag name
          return "-L"
        end

        -- Render a string of quoted args
        return table.concat(vim.tbl_map(function(v)
          v = select(1, v:gsub("\\", "\\\\"))
          return utils.str_quote("-L" .. v, { only_if_whitespace = true })
        end, value), " ")
      end,
    },
    {
      "=d", "--diff-merges=", "Determines how merge commits are treated",
      select = {
        "",
        "off",
        "on",
        "first-parent",
        "separate",
        "combined",
        "dense-combined",
        "remerge",
      },
    },
    { "=a", "--author=", "List only commits from a given author", prompt_label = "(Extended regular expression)" },
    { "=g", "--grep=", "Filter commit messages", prompt_label = "(Extended regular expression)" },
  },
}

for _, list in pairs(FHOptionPanel.flags) do
  for i, option in ipairs(list) do
    option = vim.tbl_extend("keep", option, {
      prompt_fmt = "${label}${flag_name}",

      key = utils.str_match(option[2], {
        "^%-%-?([^=]+)=?",
        "^%+%+?([^=]+)=?",
      }):gsub("%-", "_"),

      ---@param self FlagOption
      ---@param value string|string[]
      render_value = function(self, value)
        return value == "", self[2] .. utils.str_quote(value, { only_if_whitespace = true })
      end,

      ---@param value string|string[]
      render_default = function(_, value)
        if value == nil then
          return ""
        elseif type(value) == "table" then
          return table.concat(vim.tbl_map(function(v)
            v = select(1, v:gsub("\\", "\\\\"))
            return utils.str_quote(v, { only_if_whitespace = true })
          end, value), " ")
        end
        return utils.str_quote(value, { only_if_whitespace = true })
      end,
    })

    list[i] = option
    list[option.key] = option
  end
end

---FHOptionPanel constructor.
---@param parent FileHistoryPanel
---@return FHOptionPanel
function FHOptionPanel:init(parent)
  FHOptionPanel:super().init(self, {
    ---@type PanelSplitSpec
    config = {
      position = "bottom",
      height = #FHOptionPanel.flags.switches + #FHOptionPanel.flags.options + 4,
    },
    bufname = "DiffviewFHOptionPanel",
  })
  self.parent = parent
  self.emitter = EventEmitter()

  ---@param option_name string
  self.emitter:on("set_option", function(option_name)
    local log_options = self.parent:get_log_options()
    local cur_value = log_options[option_name]

    if FHOptionPanel.flags.switches[option_name] then
      self:_set_option(option_name, not cur_value)
      self:render()
      self:redraw()

    elseif FHOptionPanel.flags.options[option_name] then
      local o = FHOptionPanel.flags.options[option_name]
      local prompt = utils.str_template(o.prompt_fmt, {
        label = o.prompt_label and o.prompt_label .. " " or "",
        flag_name = o[2] .. " ",
      })
      prompt = prompt:sub(1, -2)

      if o.select then
        vim.ui.select(o.select, {
          prompt = prompt,
          format_item = function(item)
            return item == "" and "<unset>" or item
          end,
        }, function(choice)
          if choice then
            self:_set_option(option_name, choice)
          end

          self:render()
          self:redraw()
        end)

      else
        local completion = type(o.completion) == "function" and o.completion(self) or o.completion

        utils.input(prompt, {
          default = o:render_default(cur_value),
          completion = completion,
          callback = function(response)
            if response ~= "__INPUT_CANCELLED__" then
              local values

              if response == nil then
                values = { "" }
              else
                local ok
                ok, values = pcall(arg_parser.scan_sh_args, response, 1)
                if not ok then
                  utils.err(values, true)
                  return
                end
              end

              if o.transform then
                values = o.transform(values)
              else
                values = values[1]
              end

              self:_set_option(option_name, values)
            end

            self:render()
            self:redraw()
          end,
        })
      end
    end
  end)

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })

  self:on_autocmd("WinClosed", {
    callback = function()
      if not vim.deep_equal(self.option_state, self.parent:get_log_options()) then
        vim.schedule(function ()
          self.option_state = nil
          self.winid = nil
          self.parent:update_entries(function(_, status)
            if status >= JobStatus.ERROR then
              return
            end
            if not self.parent:cur_file() then
              self.parent.parent:next_item()
            end
          end)
        end)
      end
    end,
  })
end

function FHOptionPanel:_set_option(name, value)
  self.parent.log_options.single_file[name] = value
  self.parent.log_options.multi_file[name] = value
end

---@Override
function FHOptionPanel:open()
  FHOptionPanel:super().open(self)
  self.option_state = utils.tbl_deep_clone(self.parent:get_log_options())
end

function FHOptionPanel:setup_buffer()
  local conf = config.get_config()
  local default_opt = { silent = true, buffer = self.bufid }
  for lhs, mapping in pairs(conf.keymaps.option_panel) do
    if type(lhs) == "number" then
      local opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = self.bufid })
      vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
    else
      vim.keymap.set("n", lhs, mapping, default_opt)
    end
  end

  for group, _ in pairs(FHOptionPanel.flags) do
    for option_name, v in pairs(FHOptionPanel.flags[group]) do
      vim.keymap.set(
        "n",
        v[1],
        function()
          self.emitter:emit("set_option", option_name)
        end,
        { silent = true, buffer = self.bufid }
      )
    end
  end
end

function FHOptionPanel:update_components()
  local switch_schema = {}
  local option_schema = {}
  for _, option in ipairs(FHOptionPanel.flags.switches) do
    table.insert(switch_schema, { name = "switch", context = { option.key, option } })
  end
  for _, option in ipairs(FHOptionPanel.flags.options) do
    table.insert(option_schema, { name = "option", context = { option.key, option } })
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    {
      name = "switches",
      { name = "title" },
      { name = "items", unpack(switch_schema) },
    },
    {
      name = "options",
      { name = "title" },
      { name = "items", unpack(option_schema) },
    },
  })
end

---Get the file entry under the cursor.
---@return LogEntry|FileEntry|nil
function FHOptionPanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  local comp = self.components.comp:get_comp_on_line(line)
  if comp and (comp.name == "switch" or comp.name == "option") then
    return comp.context
  end
end

function FHOptionPanel:render()
  require("diffview.views.file_history.render").fh_option_panel(self)
end

M.FHOptionPanel = FHOptionPanel
return M
