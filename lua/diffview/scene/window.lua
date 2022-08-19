local File = require("diffview.git.file").File
local RevType = require("diffview.git.rev").RevType
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local api = vim.api
local M = {}

---@class Window : diffview.Object
---@field id integer
---@field file git.File
local Window = oop.create_class("Window")

Window.winopt_store = {}

---@class Window.init.opt
---@field id integer
---@field file git.File

---@param opt Window.init.opt
function Window:init(opt)
  self.id = opt.id
  self.file = opt.file
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

---@param force? boolean
function Window:close(force)
  if self:is_valid() then
    api.nvim_win_close(self.id, not not force)
    self:set_id(nil)
  end
end

function Window:load_file(callback)
  assert(self.file)

  if self.file.bufnr and api.nvim_buf_is_valid(self.file.bufnr) then
    return callback()
  end

  self.file:create_buffer(callback)
end

function Window:open_file()
  assert(self.file)

  if self:is_valid() then
    if self.file.active and self.file:is_valid() then
      api.nvim_win_set_buf(self.id, self.file.bufnr)

      if self.file.rev.type == RevType.LOCAL then
        self:_save_winopts()
      end

      self:apply_file_winopts()
      self.file:attach_buffer()
    else
      File.load_null_buffer(self.id)
      self:apply_null_winopts()
    end

    api.nvim_win_call(self.id, function()
      DiffviewGlobal.emitter:emit("diff_buf_win_enter")
    end)
  end
end

function Window:open_null()
  if self:is_valid() then
    File.load_null_buffer(self.id)
  end
end

function Window:detach_file()
  if self.file and self.file:is_valid() then
    self.file:detach_buffer()
  end
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
  if Window.winopt_store[self.file.bufnr] and api.nvim_buf_is_loaded(self.file.bufnr) then
    utils.no_win_event_call(function()
      local winid = utils.temp_win(self.file.bufnr)
      utils.set_local(winid, Window.winopt_store[self.file.bufnr])
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
    utils.set_local(self.id, self.file.winopts)
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
