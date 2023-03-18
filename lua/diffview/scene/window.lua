local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local fmt = string.format

local M = {}

local HAS_NVIM_0_8 = vim.fn.has("nvim-0.8") == 1

---@class Window : diffview.Object
---@field id integer
---@field file vcs.File
---@field parent Layout
---@field emitter EventEmitter
local Window = oop.create_class("Window")

Window.winopt_store = {}

---@class Window.init.opt
---@field id integer
---@field file vcs.File
---@field parent Layout

---@param opt Window.init.opt
function Window:init(opt)
  self.id = opt.id
  self.file = opt.file
  self.parent = opt.parent
  self.emitter = EventEmitter()

  self.emitter:on("post_open", utils.bind(self.post_open, self))
end

function Window:destroy()
  self:_restore_winopts()
  self:close(true)
end

function Window:clone()
  return Window({ file = self.file })
end

---@return boolean
function Window:is_valid()
  return self.id and api.nvim_win_is_valid(self.id)
end

---@return boolean
function Window:is_file_open()
  return self:is_valid()
    and self.file
    and self.file:is_valid()
    and api.nvim_win_get_buf(self.id) == self.file.bufnr
end

---@param force? boolean
function Window:close(force)
  if self:is_valid() then
    api.nvim_win_close(self.id, not not force)
    self:set_id(nil)
  end
end

function Window:focus()
  if self:is_valid() then
    api.nvim_set_current_win(self.id)
  end
end

function Window:is_focused()
  return self:is_valid() and api.nvim_get_current_win() == self.id
end

function Window:post_open()
  self:apply_custom_folds()
end

---@param callback fun(file: vcs.File)
function Window:load_file(callback)
  assert(self.file)

  if self.file.bufnr and api.nvim_buf_is_valid(self.file.bufnr) then
    return callback(self.file)
  end

  self.file:create_buffer(function()
    callback(self.file)
  end)
end

---@param callback? fun(file: vcs.File)
function Window:open_file(callback)
  assert(self.file)

  if self:is_valid() and self.file.active then
    local function on_load()
      local conf = config.get_config()
      api.nvim_win_set_buf(self.id, self.file.bufnr)

      if self.file.rev.type == RevType.LOCAL then
        self:_save_winopts()
      end

      if self:is_nulled() then
        self:apply_null_winopts()
      else
        self:apply_file_winopts()
      end

      self.file:attach_buffer(false, {
        keymaps = config.get_layout_keymaps(self.parent),
        disable_diagnostics = self.file.kind == "conflicting"
            and conf.view.merge_tool.disable_diagnostics,
      })

      if self:show_winbar_info() then
        vim.wo[self.id].winbar = self.file.winbar
      end

      self.emitter:emit("post_open")

      api.nvim_win_call(self.id, function()
        DiffviewGlobal.emitter:emit("diff_buf_win_enter", self.file.bufnr, self.id, {
          symbol = self.file.symbol,
          layout_name = self.parent.name,
        })
      end)

      if vim.is_callable(callback) then
        ---@cast callback -?
        callback(self.file)
      end
    end

    self.emitter:emit("pre_open")

    if self.file:is_valid() then
      on_load()
    else
      self:load_file(on_load)
    end
  end
end

---@return boolean
function Window:show_winbar_info()
  if self.file and self.file.winbar and HAS_NVIM_0_8 then
    local conf = config.get_config()
    local view = lib.get_current_view()

    if self.file.kind == "conflicting" then
      return conf.view.merge_tool.winbar_info
    else
      if view and view:class() == FileHistoryView.__get() then
        return conf.view.file_history.winbar_info
      else
        return conf.view.default.winbar_info
      end
    end
  end

  return false
end

function Window:is_nulled()
  return self:is_valid() and api.nvim_win_get_buf(self.id) == File.NULL_FILE.bufnr
end

function Window:open_null()
  if self:is_valid() then
    self.emitter:emit("pre_open")
    File.load_null_buffer(self.id)
  end
end

function Window:detach_file()
  if self.file and self.file:is_valid() then
    self.file:detach_buffer()
  end
end

---Check if the file buffer is in use in the current view's layout.
---@private
---@return boolean
function Window:_is_file_in_use()
  local view = lib.get_current_view() --[[@as StandardView? ]]

  if view and view.cur_layout ~= self.parent then
    local main = view.cur_layout:get_main_win()
    return main.file.bufnr and main.file.bufnr == self.file.bufnr
  end

  return false
end

function Window:_save_winopts()
  if Window.winopt_store[self.file.bufnr] then return end

  Window.winopt_store[self.file.bufnr] = {}
  api.nvim_win_call(self.id, function()
    for option, _ in pairs(self.file.winopts) do
      Window.winopt_store[self.file.bufnr][option] = vim.o[option]
    end
  end)
end

function Window:_restore_winopts()
  if
    Window.winopt_store[self.file.bufnr]
    and api.nvim_buf_is_loaded(self.file.bufnr)
    and not self:_is_file_in_use()
  then
    utils.no_win_event_call(function()
      local winid = utils.temp_win(self.file.bufnr)
      utils.set_local(winid, Window.winopt_store[self.file.bufnr])

      if HAS_NVIM_0_8 then
        vim.wo[winid].winbar = nil
      end

      api.nvim_win_close(winid, true)
    end)
  end
end

function Window:apply_file_winopts()
  assert(self.file)
  if self.file.winopts then
    utils.set_local(self.id, self.file.winopts)
  end
end

function Window:apply_null_winopts()
  if File.NULL_FILE.winopts then
    utils.set_local(self.id, File.NULL_FILE.winopts)
  end
end

---Use the given map of local options. These options are saved and restored
---when the file gets unloaded.
---@param opts WindowOptions
function Window:use_winopts(opts)
  if not self:is_file_open() then
    self.emitter:once("post_open", utils.bind(self.use_winopts, self, opts))
    return
  end

  local opt_store = utils.tbl_ensure(Window.winopt_store, { self.file.bufnr })

  api.nvim_win_call(self.id, function()
    for option, v in pairs(opts) do
      if opt_store[option] == nil then
        opt_store[option] = vim.o[option]
      end

      self.file.winopts[option] = v
      utils.set_local(self.id, { [option] = v })
    end
  end)
end

function Window:apply_custom_folds()
  if self.file.custom_folds
    and not self:is_nulled()
    and vim.wo[self.id].foldmethod == "manual"
  then
    api.nvim_win_call(self.id, function()
      pcall(vim.cmd, "norm! zE") -- Delete all folds in the window

      for _, fold in ipairs(self.file.custom_folds) do
        vim.cmd(fmt("%d,%dfold", fold[1], fold[2]))
        -- print(fmt("%d,%dfold", fold[1], fold[2]))
      end
    end)
  end
end

function Window:set_id(id)
  self.id = id
end

function Window:set_file(file)
  self.file = file
end

M.Window = Window
return M
