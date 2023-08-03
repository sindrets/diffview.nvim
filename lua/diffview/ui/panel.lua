local EventEmitter = require("diffview.events").EventEmitter
local File = require("diffview.vcs.file").File
local PerfTimer = require("diffview.perf").PerfTimer
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")

local api = vim.api
local logger = DiffviewGlobal.logger
local pl = utils.path

local M = {}

local uid_counter = 0

---@alias PanelConfig PanelFloatSpec|PanelSplitSpec
---@alias PanelType "split"|"float"

---@type PerfTimer
local perf = PerfTimer("[Panel] redraw")

---@class Panel : diffview.Object
---@field type PanelType
---@field config_producer PanelConfig|fun(): PanelConfig
---@field state table
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field components any
---@field bufname string
---@field au_event_map table<string, function[]>
---@field init_buffer_opts function Abstract
---@field update_components function Abstract
---@field render function Abstract
local Panel = oop.create_class("Panel")

Panel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  signcolumn = "yes",
  colorcolumn = "",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
}

Panel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  bufhidden = "hide",
  modeline = false,
  undolevels = -1,
}

Panel.default_type = "split"

---@class PanelSplitSpec
---@field type "split"
---@field position "left"|"top"|"right"|"bottom"
---@field relative "editor"|"win"
---@field win integer
---@field width? integer
---@field height? integer
---@field win_opts WindowOptions

---@type PanelSplitSpec
Panel.default_config_split = {
  type = "split",
  position = "left",
  relative = "editor",
  win = 0,
  win_opts = {}
}

---@class PanelFloatSpec
---@field type "float"
---@field relative "editor"|"win"|"cursor"
---@field win integer
---@field anchor "NW"|"NE"|"SW"|"SE"
---@field width integer
---@field height integer
---@field row number
---@field col number
---@field zindex integer
---@field style "minimal"
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]
---@field win_opts WindowOptions

---@type PanelFloatSpec
Panel.default_config_float = {
  type = "float",
  relative = "editor",
  row = 0,
  col = 0,
  zindex = 50,
  style = "minimal",
  border = "single",
  win_opts = {}
}

Panel.au = {
  ---@type integer
  group = api.nvim_create_augroup("diffview_panels", {}),
  ---@type EventEmitter
  emitter = EventEmitter(),
  ---@type table<string, integer> Map of autocmd event names to its created autocmd ID.
  events = {},
  ---Delete all autocmds with no subscribed listeners.
  prune = function()
    for event, id in pairs(Panel.au.events) do
      if #(Panel.au.emitter:get(event) or {}) == 0 then
        api.nvim_del_autocmd(id)
        Panel.au.events[event] = nil
      end
    end
  end,
}

---@class PanelSpec
---@field type PanelType
---@field config PanelConfig|fun(): PanelConfig
---@field bufname string

---@param opt PanelSpec
function Panel:init(opt)
  self.config_producer = opt.config or {}
  self.state = {}
  self.bufname = opt.bufname or "DiffviewPanel"
  self.au_event_map = {}
end

---Produce and validate config.
---@return PanelConfig
function Panel:get_config()
  local config

  if vim.is_callable(self.config_producer) then
    config = self.config_producer()
  elseif type(self.config_producer) == "table" then
    config = utils.tbl_deep_clone(self.config_producer)
  end

  ---@cast config table

  local default_config = self:get_default_config(config.type)
  config = vim.tbl_deep_extend("force", default_config, config or {}) --[[@as table ]]

  local function valid_enum(arg, values, optional)
    return {
      arg,
      function(v) return (optional and v == nil) or vim.tbl_contains(values, v) end,
      table.concat(vim.tbl_map(function(v) return ([['%s']]):format(v) end, values), "|"),
    }
  end

  vim.validate({ type = valid_enum(config.type, { "split", "float" }) })

  if config.type == "split" then
    ---@cast config PanelSplitSpec
    self.state.form = vim.tbl_contains({ "top", "bottom" }, config.position) and "row" or "column"

    vim.validate({
      position = valid_enum(config.position, { "left", "top", "right", "bottom" }),
      relative = valid_enum(config.relative, { "editor", "win" }),
      width = { config.width, "number", true },
      height = { config.height, "number", true },
      win_opts = { config.win_opts, "table" }
    })
  else
    ---@cast config PanelFloatSpec
    local border = { "none", "single", "double", "rounded", "solid", "shadow" }

    vim.validate({
      relative = valid_enum(config.relative, { "editor", "win", "cursor" }),
      win = { config.win, "n", true },
      anchor = valid_enum(config.anchor, { "NW", "NE", "SW", "SE" }, true),
      width = { config.width, "n", false },
      height = { config.height, "n", false },
      row = { config.row, "n", false },
      col = { config.col, "n", false },
      zindex = { config.zindex, "n", true },
      style = valid_enum(config.style, { "minimal" }, true),
      win_opts = { config.win_opts, "table" },
      border = {
        config.border,
        function(v)
          if v == nil then return true end

          if type(v) == "table" then
            return #v >= 2
          end

          return vim.tbl_contains(border, v)
        end,
        ("%s or a list of length >=2"):format(
          table.concat(vim.tbl_map(function(v)
            return ([['%s']]):format(v)
          end, border), "|")
        )
      },
    })
  end

  return config
end

---@param tabpage? integer
---@return boolean
function Panel:is_open(tabpage)
  local valid = self.winid and api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  elseif tabpage then
    return vim.tbl_contains(api.nvim_tabpage_list_wins(tabpage), self.winid)
  end
  return valid
end

function Panel:is_focused()
  return self:is_open() and api.nvim_get_current_win() == self.winid
end

---@param no_open? boolean Don't open the panel if it's closed.
function Panel:focus(no_open)
  if self:is_open() then
    api.nvim_set_current_win(self.winid)
  elseif not no_open then
    self:open()
    api.nvim_set_current_win(self.winid)
  end
end

function Panel:resize()
  if not self:is_open(0) then
    return
  end

  local config = self:get_config()

  if config.type == "split" then
    if self.state.form == "column" and config.width then
      api.nvim_win_set_width(self.winid, config.width)
    elseif self.state.form == "row" and config.height then
      api.nvim_win_set_height(self.winid, config.height)
    end
  elseif config.type == "float" then
    api.nvim_win_set_width(self.winid, config.width)
    api.nvim_win_set_height(self.winid, config.height)
  end
end

function Panel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  local config = self:get_config()

  if config.type == "split" then
    local split_dir = vim.tbl_contains({ "top", "left" }, config.position) and "aboveleft" or "belowright"
    local split_cmd = self.state.form == "row" and "sp" or "vsp"
    local rel_winid = config.relative == "win"
      and api.nvim_win_is_valid(config.win or -1)
      and config.win
      or 0

    api.nvim_win_call(rel_winid, function()
      vim.cmd(split_dir .. " " .. split_cmd)
      self.winid = api.nvim_get_current_win()
      api.nvim_win_set_buf(self.winid, self.bufid)

      if config.relative == "editor" then
        local dir = ({ left = "H", bottom = "J", top = "K", right = "L" })[config.position]
        vim.cmd("wincmd " .. dir)
        vim.cmd("wincmd =")
      end
    end)

  elseif config.type == "float" then
    self.winid = vim.api.nvim_open_win(self.bufid, false, utils.sanitize_float_config(config))
    if self.winid == 0 then
      self.winid = nil
      error("[diffview.nvim] Failed to open float panel window!")
    end
  end

  self:resize()
  utils.set_local(self.winid, self.class.winopts)
  utils.set_local(self.winid, config.win_opts)
end

function Panel:close()
  if self:is_open() then
    local num_wins = api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(self.winid))

    if #num_wins == 1 then
      -- Ensure that the tabpage doesn't close if the panel is the last window.
      api.nvim_win_call(self.winid, function()
        vim.cmd("sp")
        File.load_null_buffer(0)
      end)
    elseif self:is_focused() then
      vim.cmd("wincmd p")
    end

    pcall(api.nvim_win_close, self.winid, true)
  end
end

function Panel:destroy()
  self:close()
  if self:buf_loaded() then
    api.nvim_buf_delete(self.bufid, { force = true })
  end

  -- Disable autocmd listeners
  for _, cbs in pairs(self.au_event_map) do
    for _, cb in ipairs(cbs) do
      Panel.au.emitter:off(cb)
    end
  end
  Panel.au.prune()
end

---@param focus? boolean Focus the panel if it's opened.
function Panel:toggle(focus)
  if self:is_open() then
    self:close()
  elseif focus then
    self:focus()
  else
    self:open()
  end
end

function Panel:buf_loaded()
  return self.bufid and api.nvim_buf_is_loaded(self.bufid)
end

function Panel:init_buffer()
  local bn = api.nvim_create_buf(false, false)

  for k, v in pairs(self.class.bufopts) do
    api.nvim_buf_set_option(bn, k, v)
  end

  local bufname
  if pl:is_abs(self.bufname) or pl:is_uri(self.bufname) then
    bufname = self.bufname
  else
    bufname = string.format("diffview:///panels/%d/%s", Panel.next_uid(), self.bufname)
  end

  local ok = pcall(api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    api.nvim_buf_set_name(bn, bufname)
  end

  self.bufid = bn
  self.render_data = renderer.RenderData(bufname)

  api.nvim_buf_call(self.bufid, function()
    vim.api.nvim_exec_autocmds({ "BufNew", "BufFilePre" }, {
      group = Panel.au.group,
      buffer = self.bufid,
      modeline = false,
    })
  end)

  self:update_components()
  self:render()
  self:redraw()

  return bn
end

function Panel:update_components() oop.abstract_stub() end

function Panel:render() oop.abstract_stub() end

function Panel:redraw()
  if not self.render_data then
    return
  end
  perf:reset()
  renderer.render(self.bufid, self.render_data)
  perf:time()
  logger:lvl(10):debug(perf)
end

---Update components, render and redraw.
function Panel:sync()
  if self:buf_loaded() then
    self:update_components()
    self:render()
    self:redraw()
  end
end

---@class PanelAutocmdSpec
---@field callback function
---@field once? boolean

---@param event string|string[]
---@param opts PanelAutocmdSpec
function Panel:on_autocmd(event, opts)
  if type(event) ~= "table" then
    event = { event }
  end

  local callback = function(_, state)
    local win_match, buf_match
    if state.event:match("^Win") then
      if vim.tbl_contains({ "WinLeave", "WinEnter" }, state.event)
          and api.nvim_get_current_win() == self.winid
      then
        buf_match = state.buf
      else
        win_match = tonumber(state.match)
      end
    elseif state.event:match("^Buf") then
      buf_match = state.buf
    end

    if (win_match and win_match == self.winid)
      or (buf_match and buf_match == self.bufid) then
        opts.callback(state)
    end
  end

  for _, e in ipairs(event) do
    if not self.au_event_map[e] then
      self.au_event_map[e] = {}
    end
    table.insert(self.au_event_map[e], callback)

    if not Panel.au.events[e] then
      Panel.au.events[e] = api.nvim_create_autocmd(e, {
        group = Panel.au.group,
        callback = function(state)
          Panel.au.emitter:emit(e, state)
        end,
      })
    end

    if opts.once then
      Panel.au.emitter:once(e, callback)
    else
      Panel.au.emitter:on(e, callback)
    end
  end
end

---Unsubscribe an autocmd listener. If no event is given, the callback is
---disabled for all events.
---@param callback function
---@param event? string
function Panel:off_autocmd(callback, event)
  for e, cbs in pairs(self.au_event_map) do
    if (event == nil or event == e) and utils.vec_indexof(cbs, callback) ~= -1 then
      Panel.au.emitter:off(callback, event)
    end
    Panel.au.prune()
  end
end

function Panel:get_default_config(panel_type)
  local producer = self.class["default_config_" .. (panel_type or self.class.default_type)]

  local config
  if vim.is_callable(producer) then
    config = producer()
  elseif type(producer) == "table" then
    config = producer
  end

  return config
end

---@return integer?
function Panel:get_width()
  if self:is_open() then
    return api.nvim_win_get_width(self.winid)
  end
end

---@return integer?
function Panel:get_height()
  if self:is_open() then
    return api.nvim_win_get_height(self.winid)
  end
end

function Panel:infer_width()
  local cur_width = self:get_width()
  if cur_width then return cur_width end

  local config = self:get_config()
  if config.width then return config.width end

  -- PanelFloatSpec requires both width and height to be defined. If we get
  -- here then the panel is a split.
  ---@cast config PanelSplitSpec

  if config.win and api.nvim_win_is_valid(config.win) then
    if self.state.form == "row" then
      return api.nvim_win_get_width(config.win)
    elseif self.state.form == "column" then
      return math.floor(api.nvim_win_get_width(config.win) / 2)
    end
  end

  if self.state.form == "row" then
    return vim.o.columns
  end

  return math.floor(vim.o.columns / 2)
end

function Panel:infer_height()
  local cur_height = self:get_height()
  if cur_height then return cur_height end

  local config = self:get_config()
  if config.height then return config.height end

  -- PanelFloatSpec requires both width and height to be defined. If we get
  -- here then the panel is a split.
  ---@cast config PanelSplitSpec

  if config.win and api.nvim_win_is_valid(config.win) then
    if self.state.form == "row" then
      return math.floor(api.nvim_win_get_height(config.win) / 2)
    elseif self.state.form == "column" then
      return api.nvim_win_get_height(config.win)
    end
  end

  if self.state.form == "row" then
    return math.floor(vim.o.lines / 2)
  end

  return vim.o.lines
end

function Panel.next_uid()
  local uid = uid_counter
  uid_counter = uid_counter + 1
  return uid
end

M.Panel = Panel
return M
