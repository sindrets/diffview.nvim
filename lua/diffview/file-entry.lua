local utils = require'diffview.utils'
local config = require'diffview.config'
local RevType = require'diffview.rev'.RevType
local a = vim.api
local M = {}

---@class GitStats
---@field additions integer
---@field deletions integer

---@class FileEntry
---@field path string
---@field oldpath string
---@field basename string
---@field status string
---@field stats GitStats
---@field left Rev
---@field right Rev
---@field left_bufid integer
---@field right_bufid integer
---@field created_bufs integer[]
local FileEntry = {}
FileEntry.__index = FileEntry

FileEntry.winopts = {
  diff = true,
  scrollbind = true,
  cursorbind = true,
  foldmethod = "diff",
  foldlevel = 0
}

---FileEntry constructor
---@param opt table
---@return FileEntry
function FileEntry:new(opt)
  local this = {
    path = opt.path,
    oldpath = opt.oldpath,
    basename = utils.path_basename(opt.path),
    status = opt.status,
    stats = opt.stats,
    left = opt.left,
    right = opt.right,
    created_bufs = {}
  }
  setmetatable(this, self)
  return this
end

function FileEntry:destroy()
  self:detach_buffers()
  for _, bn in ipairs(self.created_bufs) do
    pcall(a.nvim_buf_delete, bn, {})
  end
end

---Load the buffers.
---@param git_root string
---@param left_winid integer
---@param right_winid integer
function FileEntry:load_buffers(git_root, left_winid, right_winid)
  local splits = {
    { winid = left_winid, bufid = self.left_bufid, rev = self.left },
    { winid = right_winid, bufid = self.right_bufid, rev = self.right }
  }

  for _, split in ipairs(splits) do
    a.nvim_set_current_win(split.winid)
    if not (split.bufid and a.nvim_buf_is_loaded(split.bufid)) then
      if split.rev.type == RevType.LOCAL then
        vim.cmd("e " .. vim.fn.fnameescape(self.path))
        split.bufid = a.nvim_get_current_buf()
      elseif split.rev.type == RevType.COMMIT then
        local bn
        if self.oldpath then
          bn = M._create_buffer(git_root, split.rev, self.oldpath, false)
        else
          bn = M._create_buffer(git_root, split.rev, self.path, self.status == "?")
        end
        table.insert(self.created_bufs, bn)
        a.nvim_win_set_buf(split.winid, bn)
        split.bufid = bn
        vim.cmd("filetype detect")
      end
      M._attach_buffer(split.bufid)
    else
      a.nvim_win_set_buf(split.winid, split.bufid)
      M._attach_buffer(split.bufid)
    end
  end

  self.left_bufid = splits[1].bufid
  self.right_bufid = splits[2].bufid

  M._update_windows(left_winid, right_winid)
end

function FileEntry:attach_buffers()
  if self.left_bufid then M._attach_buffer(self.left_bufid) end
  if self.right_bufid then M._attach_buffer(self.right_bufid) end
end

function FileEntry:detach_buffers()
  if self.left_bufid then M._detach_buffer(self.left_bufid) end
  if self.right_bufid then M._detach_buffer(self.right_bufid) end
end

function M._create_buffer(git_root, rev, path, null)
  local bn = a.nvim_create_buf(false, false)

  if not null then
    local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " show " .. rev.commit .. ":" .. vim.fn.shellescape(path)
    local lines = vim.fn.systemlist(cmd)
    a.nvim_buf_set_lines(bn, 0, 0, false, lines)
  end

  local commit_abbrev = rev.commit:sub(1,7)
  local basename = utils.path_basename(path)
  local bufname = commit_abbrev .. "_" .. basename
  a.nvim_buf_set_option(bn, "modified", false)

  local ok = pcall(a.nvim_buf_set_name, bn, bufname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    while not ok do
      ok = pcall(a.nvim_buf_set_name, bn, i .. "_" .. bufname)
      i = i + 1
    end
  end

  return bn
end

function M._update_windows(left_winid, right_winid)
  for _, id in ipairs({ left_winid, right_winid }) do
    for k, v in pairs(FileEntry.winopts) do
      a.nvim_win_set_option(id, k, v)
    end
  end
end

function M._attach_buffer(bufid)
  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings) do
    a.nvim_buf_set_keymap(bufid, "n", lhs, rhs, { noremap = true, silent = true })
  end
end

function M._detach_buffer(bufid)
  local conf = config.get_config()
  for lhs, _ in pairs(conf.key_bindings) do
    pcall(a.nvim_buf_del_keymap, bufid, "n", lhs)
  end
end

M.FileEntry = FileEntry

return M
