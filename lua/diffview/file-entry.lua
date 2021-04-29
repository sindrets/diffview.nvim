local utils = require'diffview.utils'
local config = require'diffview.config'
local RevType = require'diffview.rev'.RevType
local a = vim.api
local M = {}

---@class FileEntry
---@field path string
---@field oldpath string
---@field status string
---@field left Rev
---@field right Rev
---@field left_bufid integer
---@field right_bufid integer
local FileEntry = {}
FileEntry.__index = FileEntry

---FileEntry constructor
---@param opt table
---@return FileEntry
function FileEntry:new(opt)
  local this = {
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    left = opt.left,
    right = opt.right
  }
  setmetatable(this, self)
  return this
end

---Load the buffers.
---@param git_root string
---@param left_winid integer
---@param right_winid integer
function FileEntry:load_buffers(git_root, left_winid, right_winid)
  a.nvim_set_current_win(left_winid)
  if not (self.left_bufid and a.nvim_buf_is_loaded(self.left_bufid)) then
    if self.left.type == RevType.LOCAL then
      vim.cmd("e " .. vim.fn.fnameescape(self.path))
      self.left_bufid = a.nvim_get_current_buf()
    elseif self.left.type == RevType.COMMIT then
      local bn
      if self.oldpath then
        bn = M._create_buffer(git_root, self.left, self.oldpath, false)
      else
        bn = M._create_buffer(git_root, self.left, self.path, self.status == "?")
      end
      a.nvim_win_set_buf(left_winid, bn)
      self.left_bufid = bn
      vim.cmd("filetype detect")
    end
    M._init_buffer(self.left_bufid)
  else
    a.nvim_win_set_buf(left_winid, self.left_bufid)
  end

  a.nvim_set_current_win(right_winid)
  if not (self.right_bufid and a.nvim_buf_is_loaded(self.right_bufid)) then
    if self.right.type == RevType.LOCAL then
      vim.cmd("e " .. vim.fn.fnameescape(self.path))
      self.right_bufid = a.nvim_get_current_buf()
    elseif self.right.type == RevType.COMMIT then
      local bn
      if self.oldpath then
        bn = M._create_buffer(git_root, self.right, self.oldpath, false)
      else
        bn = M._create_buffer(git_root, self.right, self.path, self.status == "?")
      end
      a.nvim_win_set_buf(right_winid, bn)
      self.right_bufid = bn
      vim.cmd("filetype detect")
    end
    M._init_buffer(self.right_bufid)
  else
    a.nvim_win_set_buf(right_winid, self.right_bufid)
  end

  M._update_windows(left_winid, right_winid)
end

function M._create_buffer(git_root, rev, path, null)
  local bn = a.nvim_create_buf(false, false)

  if not null then
    local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " show " .. rev.commit .. ":" .. vim.fn.shellescape(path)
    local lines = vim.fn.systemlist(cmd)
    a.nvim_buf_set_lines(bn, 0, 0, false, lines)
  end

  local basename = utils.path_basename(path)
  local ext = basename:match(".*(%..*)") or ""
  if ext ~= "" then basename = basename:match("(.*)%..*") end
  local commit_abbrev = rev.commit:sub(1,7)
  a.nvim_buf_set_name(bn, basename .. "_" .. commit_abbrev .. ext)
  a.nvim_buf_set_option(bn, "modified", false)

  return bn
end

function M._init_buffer(bufid)
  local conf = config.get_config()
  for mapping, value in pairs(conf.key_bindings) do
    a.nvim_buf_set_keymap(bufid, "n", mapping, value, { noremap = true, silent = true })
  end
end

function M._update_windows(left_winid, right_winid)
  for _, id in ipairs({left_winid, right_winid}) do
    a.nvim_win_set_option(id, "diff", true)
    a.nvim_win_set_option(id, "scrollbind", true)
    a.nvim_win_set_option(id, "cursorbind", true)
    a.nvim_win_set_option(id, "foldmethod", "diff")
    a.nvim_win_set_option(id, "foldlevel", 0)
  end
end

M.FileEntry = FileEntry

return M
