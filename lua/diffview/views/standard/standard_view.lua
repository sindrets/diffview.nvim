local oop = require("diffview.oop")
local utils = require("diffview.utils")
local git = require("diffview.git")
local Event = require("diffview.events").Event
local FileEntry = require("diffview.views.file_entry").FileEntry
local RevType = require("diffview.rev").RevType
local Diff = require("diffview.diff").Diff
local EditToken = require("diffview.diff").EditToken
local View = require("diffview.views.view").View
local LayoutMode = require("diffview.views.view").LayoutMode
local FilePanel = require("diffview.views.standard.file_panel").FilePanel
local api = vim.api

local M = {}

local win_reset_opts = {
  diff = false,
  cursorbind = false,
  scrollbind = false,
}

---@class StandardViewOptions
---@field show_untracked boolean|nil

---@class StandardView
---@field git_root string Absolute path the root of the git directory.
---@field git_dir string Absolute path to the '.git' directory.
---@field rev_arg string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field options StandardViewOptions
---@field file_panel FilePanel
---@field left_winid integer
---@field right_winid integer
---@field files FileDict
---@field file_idx integer
---@field nulled boolean
local StandardView = View
StandardView = oop.create_class("StandardView", View)

---StandardView constructor
---@return StandardView
function StandardView:init(opt)
  self.super:init()
  self.git_root = opt.git_root
  self.git_dir = git.git_dir(opt.git_root)
  self.rev_arg = opt.rev_arg
  self.path_args = opt.path_args
  self.left = opt.left
  self.right = opt.right
  self.options = opt.options
  self.files = git.diff_file_list(opt.git_root, opt.left, opt.right, opt.path_args, opt.options)
  self.file_idx = 1
  self.nulled = false
  self.file_panel = FilePanel(
    self.git_root,
    self.files,
    self.path_args,
    self.rev_arg or git.rev_to_pretty_string(self.left, self.right)
  )
  FileEntry.update_index_stat(self.git_root, self.git_dir)
end

---@Override
function StandardView:open()
  vim.cmd("tab split")
  self.tabpage = api.nvim_get_current_tabpage()
  self:init_layout()
  self:init_event_listeners()
  vim.schedule(function()
    local file = self:cur_file()
    if file then
      self:set_file(file)
    else
      self:file_safeguard()
    end
    self.ready = true
  end)
end

---@Override
function StandardView:close()
  for _, file in self.files:ipairs() do
    file:destroy()
  end

  self.file_panel:destroy()

  if self.tabpage and api.nvim_tabpage_is_valid(self.tabpage) then
    local pagenr = api.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end
end

---@Override
function StandardView:init_layout()
  local split_cmd = self.layout_mode == LayoutMode.VERTICAL and "sp" or "vsp"
  self.left_winid = api.nvim_get_current_win()
  FileEntry.load_null_buffer(self.left_winid)
  vim.cmd("belowright " .. split_cmd)
  self.right_winid = api.nvim_get_current_win()
  FileEntry.load_null_buffer(self.right_winid)
  self.file_panel:open()
end

---Get the current file.
---@return FileEntry
function StandardView:cur_file()
  if self.files:size() > 0 then
    return self.files[utils.clamp(self.file_idx, 1, self.files:size())]
  end
  return nil
end

function StandardView:next_file()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    self.file_idx = self.file_idx % self.files:size() + 1
    vim.cmd("diffoff!")
    cur = self.files[self.file_idx]
    cur:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false

    return cur
  end
end

function StandardView:prev_file()
  self:ensure_layout()
  if self:file_safeguard() then
    return
  end

  if self.files:size() > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    self.file_idx = (self.file_idx - 2) % self.files:size() + 1
    vim.cmd("diffoff!")
    cur = self.files[self.file_idx]
    cur:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false

    return cur
  end
end

function StandardView:set_file(file, focus)
  self:ensure_layout()
  if self:file_safeguard() or not file then
    return
  end

  for i, f in self.files:ipairs() do
    if f == file then
      local cur = self:cur_file()
      if cur then
        cur:detach_buffers()
      end
      self.file_idx = i
      vim.cmd("diffoff!")
      self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
      self.file_panel:highlight_file(self:cur_file())
      self.nulled = false

      if focus then
        api.nvim_set_current_win(self.right_winid)
      end
    end
  end
end

function StandardView:set_file_by_path(path, focus)
  ---@type FileEntry
  for _, file in self.files:ipairs() do
    if file.path == path then
      self:set_file(file, focus)
      return
    end
  end
end

---Get an updated list of files.
---@return FileDict
function StandardView:get_updated_files()
  return git.diff_file_list(self.git_root, self.left, self.right, self.path_args, self.options)
end

---Update the file list, including stats and status for all files.
function StandardView:update_files()
  self:ensure_layout()

  -- If left is tracking HEAD and right is LOCAL: Update HEAD rev.
  local new_head
  if self.left.head and self.right.type == RevType.LOCAL then
    new_head = git.head_rev(self.git_root)
    if new_head and self.left.commit ~= new_head.commit then
      self.left = new_head
    else
      new_head = nil
    end
  end

  local index_stat = vim.loop.fs_stat(utils.path_join({ self.git_dir, "index" }))
  local last_winid = api.nvim_get_current_win()
  local new_files = self:get_updated_files()
  local files = {
    { cur_files = self.files.working, new_files = new_files.working },
    { cur_files = self.files.staged, new_files = new_files.staged },
  }

  for _, v in ipairs(files) do
    local diff = Diff(v.cur_files, v.new_files, function(aa, bb)
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
        v.cur_files[ai]:validate_index_buffers(self.git_root, self.git_dir, index_stat)
        if new_head and v.cur_files[ai].left.head then
          v.cur_files[ai].left = new_head
          v.cur_files[ai]:dispose_buffer("left")
        end
        ai = ai + 1
        bi = bi + 1
      elseif opr == EditToken.DELETE then
        if cur_file == v.cur_files[ai] then
          cur_file = self:prev_file()
        end
        v.cur_files[ai]:destroy()
        table.remove(v.cur_files, ai)
      elseif opr == EditToken.INSERT then
        table.insert(v.cur_files, ai, v.new_files[bi])
        if ai <= self.file_idx then
          self.file_idx = self.file_idx + 1
        end
        ai = ai + 1
        bi = bi + 1
      elseif opr == EditToken.REPLACE then
        if cur_file == v.cur_files[ai] then
          cur_file = self:prev_file()
        end
        v.cur_files[ai]:destroy()
        table.remove(v.cur_files, ai)
        table.insert(v.cur_files, ai, v.new_files[bi])
        ai = ai + 1
        bi = bi + 1
      end
    end
  end

  FileEntry.update_index_stat(self.git_root, self.git_dir, index_stat)
  self.file_panel:render()
  self.file_panel:redraw()
  self.file_idx = utils.clamp(self.file_idx, 1, self.files:size())
  self:set_file(self:cur_file())

  if api.nvim_win_is_valid(last_winid) then
    api.nvim_set_current_win(last_winid)
  end

  self.update_needed = false
end

---@Override
---Checks the state of the view layout.
---@return LayoutState
function StandardView:validate_layout()
  ---@class LayoutState
  ---@field tabpage boolean
  ---@field left_win boolean
  ---@field right_win boolean
  ---@field valid boolean
  local state = {
    tabpage = api.nvim_tabpage_is_valid(self.tabpage),
    left_win = api.nvim_win_is_valid(self.left_winid),
    right_win = api.nvim_win_is_valid(self.right_winid),
  }
  state.valid = state.tabpage and state.left_win and state.right_win
  return state
end

---@Override
---Recover the layout after the user has messed it up.
---@param state LayoutState
function StandardView:recover_layout(state)
  self.ready = false

  if not state.tabpage then
    vim.cmd("tab split")
    self.tabpage = api.nvim_get_current_tabpage()
    self.file_panel:close()
    self:init_layout()
    self.ready = true
    return
  end

  api.nvim_set_current_tabpage(self.tabpage)
  self.file_panel:close()
  local split_cmd = self.layout_mode == LayoutMode.VERTICAL and "sp" or "vsp"

  if not state.left_win and not state.right_win then
    self:init_layout()
  elseif not state.left_win then
    api.nvim_set_current_win(self.right_winid)
    vim.cmd("aboveleft " .. split_cmd)
    self.left_winid = api.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())
  elseif not state.right_win then
    api.nvim_set_current_win(self.left_winid)
    vim.cmd("belowright " .. split_cmd)
    self.right_winid = api.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())
  end

  self.ready = true
end

---@Override
---Ensure both left and right windows exist in the view's tabpage.
function StandardView:ensure_layout()
  local state = self:validate_layout()
  if not state.valid then
    self:recover_layout(state)
  end
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function StandardView:file_safeguard()
  if self.files:size() == 0 then
    local cur = self:cur_file()
    if cur then
      cur:detach_buffers()
    end
    FileEntry.load_null_buffer(self.left_winid)
    FileEntry.load_null_buffer(self.right_winid)
    self.nulled = true
    return true
  end
  return false
end

---Disable unwanted options in all windows not part of the view.
function StandardView:fix_foreign_windows()
  local win_ids = api.nvim_tabpage_list_wins(self.tabpage)
  for _, id in ipairs(win_ids) do
    if not (id == self.file_panel.winid or id == self.left_winid or id == self.right_winid) then
      for k, v in pairs(win_reset_opts) do
        api.nvim_win_set_option(id, k, v)
      end
    end
  end
end

function StandardView:on_files_staged(callback)
  self.emitter:on(Event.FILES_STAGED, callback)
end

function StandardView:init_event_listeners()
  local listeners = require("diffview.views.standard.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

---Infer the current selected file. If the file panel is focused: return the
---file entry under the cursor. Otherwise return the file open in the view.
---Returns nil if no file is open in the view, or there is no entry under the
---cursor in the file panel.
---@return FileEntry|nil
function StandardView:infer_cur_file()
  if self.file_panel:is_focused() then
    return self.file_panel:get_file_at_cursor()
  else
    return self:cur_file()
  end
end

M.StandardView = StandardView

return M
