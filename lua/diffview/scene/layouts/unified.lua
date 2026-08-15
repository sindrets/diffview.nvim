local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")

local Window = lazy.access("diffview.scene.window", "Window") ---@type Window|LazyModule
local unified = lazy.require("diffview.vcs.unified") ---@module "diffview.vcs.unified"

local api = vim.api
local await = async.await

local M = {}

---A single window showing the diff inline: the file as it looks after the
---change, with the removed lines spliced back in.
---
---This is the equivalent of VSCode's inline diff view.
---@class Unified : Layout
---@field b Window
local Unified = oop.create_class("Unified", Layout)

---@alias Unified.WindowSymbol "b"

---@class Unified.init.Opt
---@field b vcs.File
---@field winid_b integer

Unified.name = "unified"

---@param opt Unified.init.Opt
function Unified:init(opt)
  self:super()
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self:use_windows(self.b)
end

---@override
---@param self Unified
---@param pivot integer?
Unified.create = async.void(function(self, pivot)
  self:create_pre()
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.b then
      self.b:set_id(curwin)
    else
      self.b = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)
  self.windows = { self.b }
  await(self:create_post())
  self:render()
end)

---@param file vcs.File
function Unified:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---@param self Unified
---@param entry FileEntry
Unified.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Unified ]]
  assert(layout:instanceof(Unified))

  self:set_file_b(layout.b.file)

  if self:is_valid() then
    await(self:open_files())
    self:render()
  end
end)

---Apply the diff highlights to the buffer.
function Unified:render()
  local file = self.b and self.b.file

  if file and file.unified_data and file:is_valid() then
    unified.apply_highlights(file.bufnr, file.unified_data)
  end
end

function Unified:get_main_win()
  return self.b
end

---@override
---@diagnostic disable-next-line: unused-local
function Unified.should_null(rev, status, sym)
  return false
end

M.Unified = Unified
return M
