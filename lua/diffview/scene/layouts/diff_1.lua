local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Layout = require("diffview.scene.layout").Layout
local oop = require("diffview.oop")

local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local Rev = lazy.access("diffview.vcs.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local Window = lazy.access("diffview.scene.window", "Window") ---@type Window|LazyModule

local api = vim.api
local await = async.await

local M = {}

---@class Diff1 : Layout
---@field b Window
local Diff1 = oop.create_class("Diff1", Layout)

---@alias Diff1.WindowSymbol "b"

---@class Diff1.init.Opt
---@field b vcs.File
---@field winid_b integer

Diff1.name = "diff1_plain"

---@param opt Diff1.init.Opt
function Diff1:init(opt)
  self:super()
  self.b = Window({ file = opt.b, id = opt.winid_b })
  self:use_windows(self.b)
end

---@override
---@param self Diff1
---@param pivot integer?
Diff1.create = async.void(function(self, pivot)
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
end)

---@param file vcs.File
function Diff1:set_file_b(file)
  self.b:set_file(file)
  file.symbol = "b"
end

---@param self Diff1
---@param entry FileEntry
Diff1.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Diff1 ]]
  assert(layout:instanceof(Diff1))

  self:set_file_b(layout.b.file)

  if self:is_valid() then
    await(self:open_files())
  end
end)

function Diff1:get_main_win()
  return self.b
end

---@param layout Diff3
---@return Diff3
function Diff1:to_diff3(layout)
  assert(layout:instanceof(Diff3.__get()))
  local main = self:get_main_win().file

  return layout({
    a = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 2),
      nulled = false, -- FIXME
    }),
    b = self.b.file,
    c = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 3),
      nulled = false, -- FIXME
    }),
  })
end

---@param layout Diff4
---@return Diff4
function Diff1:to_diff4(layout)
  assert(layout:instanceof(Diff4.__get()))
  local main = self:get_main_win().file

  return layout({
    a = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 2),
      nulled = false, -- FIXME
    }),
    b = self.b.file,
    c = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 3),
      nulled = false, -- FIXME
    }),
    d = File({
      adapter = main.adapter,
      path = main.path,
      kind = main.kind,
      commit = main.commit,
      get_data = main.get_data,
      rev = Rev(RevType.STAGE, 1),
      nulled = false, -- FIXME
    })
  })
end

---FIXME
---@override
---@param rev Rev
---@param status string Git status symbol.
---@param sym Diff1.WindowSymbol
function Diff1.should_null(rev, status, sym)
  return false
end

M.Diff1 = Diff1
return M
