local utils = require'diffview.utils'
local git = require'diffview.git'
local FileEntry = require'diffview.file-entry'.FileEntry
local RevType = require'diffview.rev'.RevType
local Diff = require'diffview.diff'.Diff
local EditToken = require'diffview.diff'.EditToken
local FilePanel = require'diffview.file-panel'.FilePanel
local a = vim.api
local M = {}

local win_reset_opts = {
  diff = false,
  cursorbind = false,
  scrollbind = false
}

---@class LayoutMode

---@class ELayoutMode
---@field HORIZONTAL LayoutMode
---@field VERTICAL LayoutMode
local LayoutMode = utils.enum {
  "HORIZONTAL",
  "VERTICAL"
}

---@class ViewOptions
---@field show_untracked boolean|nil

---@class View
---@field tabpage integer
---@field git_root string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field options ViewOptions
---@field layout_mode LayoutMode
---@field file_panel FilePanel
---@field left_winid integer
---@field right_winid integer
---@field files FileDict
---@field file_idx integer
---@field nulled boolean
---@field ready boolean
local View = utils.class()

---View constructor
---@return View
function View:new(opt)
  local this = {
    git_root = opt.git_root,
    path_args = opt.path_args,
    left = opt.left,
    right = opt.right,
    options = opt.options,
    layout_mode = View.get_layout_mode(),
    files = git.diff_file_list(opt.git_root, opt.left, opt.right, opt.path_args, opt.options),
    file_idx = 1,
    nulled = false,
    ready = false
  }
  this.file_panel = FilePanel:new(
    this.git_root,
    this.files,
    this.path_args,
    git.rev_to_pretty_string(this.left, this.right)
  )
  setmetatable(this, self)
  return this
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = a.nvim_get_current_tabpage()
  self:init_layout()
  local file = self:cur_file()
  if file then
    self:set_file(file)
  else
    self:file_safeguard()
  end
  self.ready = true
end

function View:close()
  for _, file in self.files:ipairs() do
    file:destroy()
  end

  self.file_panel:destroy()

  if self.tabpage and a.nvim_tabpage_is_valid(self.tabpage) then
    local pagenr = a.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end
end

function View:init_layout()
  local split_cmd = self.layout_mode == LayoutMode.VERTICAL and "sp" or "vsp"
  self.left_winid = a.nvim_get_current_win()
  vim.cmd("belowright " .. split_cmd)
  self.right_winid = a.nvim_get_current_win()
  self.file_panel:open()
end

---Get the current file.
---@return FileEntry
function View:cur_file()
  if self.files:size() > 0 then
    return self.files[utils.clamp(self.file_idx, 1, self.files:size())]
  end
  return nil
end

function View:next_file()
  self:ensure_layout()
  if self:file_safeguard() then return end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    self.file_idx = (self.file_idx) % self.files:size() + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false
  end
end

function View:prev_file()
  self:ensure_layout()
  if self:file_safeguard() then return end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    self.file_idx = (self.file_idx - 2) % self.files:size() + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false
  end
end

function View:set_file(file, focus)
  self:ensure_layout()
  if self:file_safeguard() or not file then return end

  for i, f in self.files:ipairs() do
    if f == file then
      local cur = self:cur_file()
      if cur then cur:detach_buffers() end
      self.file_idx = i
      vim.cmd("diffoff!")
      self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
      self.file_panel:highlight_file(self:cur_file())
      self.nulled = false

      if focus then
        a.nvim_set_current_win(self.right_winid)
      end
    end
  end
end

function View:set_file_by_path(path, focus)
  for _, file in self.files:ipairs() do
    if file.path == path then
      self:set_file(file, focus)
      return
    end
  end
end

---Get an updated list of files.
---@return FileDict
function View:get_updated_files()
  return git.diff_file_list(
    self.git_root, self.left, self.right, self.path_args, self.options
  )
end

---Update the file list, including stats and status for all files.
function View:update_files()
  -- If left is tracking HEAD and right is LOCAL: Update HEAD rev.
  if self.left.head and self.right.type == RevType.LOCAL then
    local new_head = git.head_rev(self.git_root)
    if new_head and self.left.commit ~= new_head.commit then
      self.left = new_head
    end
  end

  local new_files = self:get_updated_files()
  local files = {
    { cur_files = self.files.working, new_files = new_files.working },
    { cur_files = self.files.staged, new_files = new_files.staged }
  }

  for _, v in ipairs(files) do
    local diff = Diff:new(v.cur_files, v.new_files, function (aa, bb)
      return aa.path == bb.path
    end)
    local script = diff:create_edit_script()
    local cur_file = self:cur_file()

    local ai = 1
    local bi = 1
    for _, opr in ipairs(script) do
      if opr == EditToken.NOOP then
        -- Update status and stats
        v.cur_files[ai].status = v.new_files[bi].status
        v.cur_files[ai].stats = v.new_files[bi].stats
        ai = ai + 1
        bi = bi + 1
      elseif opr == EditToken.DELETE then
        if cur_file == v.cur_files[ai] then self:prev_file() end
        v.cur_files[ai]:destroy()
        table.remove(v.cur_files, ai)
      elseif opr == EditToken.INSERT then
        table.insert(v.cur_files, ai, v.new_files[bi])
        ai = ai + 1
        bi = bi + 1
      elseif opr == EditToken.REPLACE then
        if cur_file == v.cur_files[ai] then self:prev_file() end
        v.cur_files[ai]:destroy()
        table.remove(v.cur_files, ai)
        table.insert(v.cur_files, ai, v.new_files[bi])
        ai = ai + 1
        bi = bi + 1
      end
    end
  end

  self.file_panel:render()
  self.file_panel:redraw()
  self.file_idx = utils.clamp(self.file_idx, 1, self.files:size())
  self:set_file(self:cur_file())

  self.update_needed = false
end

---Checks the state of the view layout.
---@return LayoutState
function View:validate_layout()
  ---@class LayoutState
  ---@field tabpage boolean
  ---@field left_win boolean
  ---@field right_win boolean
  ---@field valid boolean
  local state = {
    tabpage = a.nvim_tabpage_is_valid(self.tabpage),
    left_win = a.nvim_win_is_valid(self.left_winid),
    right_win = a.nvim_win_is_valid(self.right_winid)
  }
  state.valid = state.tabpage and state.left_win and state.right_win
  return state
end

---Recover the layout after the user has messed it up.
---@param state LayoutState
function View:recover_layout(state)
  self.ready = false

  if not state.tabpage then
    vim.cmd("tab split")
    self.tabpage = a.nvim_get_current_tabpage()
    self.file_panel:close()
    self:init_layout()
    self.ready = true
    return
  end

  a.nvim_set_current_tabpage(self.tabpage)
  self.file_panel:close()
  local split_cmd = self.layout_mode == LayoutMode.VERTICAL and "sp" or "vsp"

  if not state.left_win and not state.right_win then
    self:init_layout()

  elseif not state.left_win then
    a.nvim_set_current_win(self.right_winid)
    vim.cmd("aboveleft " .. split_cmd)
    self.left_winid = a.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())

  elseif not state.right_win then
    a.nvim_set_current_win(self.left_winid)
    vim.cmd("belowright " .. split_cmd)
    self.right_winid = a.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())
  end

  self.ready = true
end

---Ensure both left and right windows exist in the view's tabpage.
function View:ensure_layout()
  local state = self:validate_layout()
  if not state.valid then
    self:recover_layout(state)
  end
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function View:file_safeguard()
  if self.files:size() == 0 then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    FileEntry.load_null_buffer(self.left_winid)
    FileEntry.load_null_buffer(self.right_winid)
    self.nulled = true
    return true
  end
  return false
end

function View:on_enter()
  if self.ready then
    self:update_files()
  end

  local file = self:cur_file()
  if file then
    file:attach_buffers()
  end
end

function View:on_leave()
  local file = self:cur_file()
  if file then
    file:detach_buffers()
  end
end

function View:on_buf_write_post()
  if git.has_local(self.left, self.right) then
    self.update_needed = true
    if a.nvim_get_current_tabpage() == self.tabpage then
      self:update_files()
    end
  end
end

function View:on_win_leave()
  if self.ready and a.nvim_tabpage_is_valid(self.tabpage) then
    self:fix_foreign_windows()
  end
end

---Disable unwanted options in all windows not part of the view.
function View:fix_foreign_windows()
  local win_ids = a.nvim_tabpage_list_wins(self.tabpage)
  for _, id in ipairs(win_ids) do
    if not (
        id == self.file_panel.winid
        or id == self.left_winid
        or id == self.right_winid) then
      for k, v in pairs(win_reset_opts) do
        a.nvim_win_set_option(id, k, v)
      end
    end
  end
end

function View.get_layout_mode()
  local diffopts = utils.str_split(vim.o.diffopt, ",")
  if vim.tbl_contains(diffopts, "horizontal") then
    return LayoutMode.VERTICAL
  else
    return LayoutMode.HORIZONTAL
  end
end

M.LayoutMode = LayoutMode
M.View = View

return M
