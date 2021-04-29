local git = require'diffview.git'
local a = vim.api
local M = {}

---@class View
---@field tabpage integer
---@field git_root string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field left_winid integer
---@field right_winid integer
---@field files FileEntry[]
---@field file_idx integer
local View = {}
View.__index = View

---View constructor
---@return View
function View:new(opt)
  local this = {
    git_root = opt.git_root,
    path_args = opt.paths,
    left = opt.left,
    right = opt.right,
    files = git.diff_file_list(opt.git_root, opt.left, opt.right),
    file_idx = 1
  }
  setmetatable(this, self)
  return this
end

function View:open()
  vim.cmd("tabnew")
  self.tabpage = a.nvim_get_current_tabpage()
  self:init_layout()
  if #self.files > 0 then
    self.files[1]:load_buffers(self.git_root, self.left_winid, self.right_winid)
  end
end

function View:close()
  for _, file in ipairs(self.files) do
    file:destroy()
  end

  if self.tabpage and a.nvim_tabpage_is_valid(self.tabpage) then
    local ok = true
    if a.nvim_get_current_tabpage() ~= self.tabpage then
      ok = pcall(a.nvim_set_current_tabpage, self.tabpage)
    end
    if ok then vim.cmd("tabclose") end
  end
end

function View:init_layout()
  self.left_winid = a.nvim_get_current_win()
  vim.cmd("belowright vsp")
  self.right_winid = a.nvim_get_current_win()
end

function View:cur_file()
  if #self.files > 0 then
    return self.files[self.file_idx]
  end
  return nil
end

function View:next_file()
  if #self.files > 1 then
    self.files[self.file_idx]:detach_buffers()
    self.file_idx = (self.file_idx) % #self.files + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
  end
end

function View:prev_file()
  if #self.files > 1 then
    self.files[self.file_idx]:detach_buffers()
    self.file_idx = (self.file_idx - 2) % #self.files + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
  end
end

function View:on_enter()
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

M.View = View

return M
