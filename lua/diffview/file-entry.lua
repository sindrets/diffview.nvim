local utils = require'diffview.utils'
local config = require'diffview.config'
local RevType = require'diffview.rev'.RevType
local a = vim.api
local M = {}

---@type integer|nil
M._null_buffer = nil

---@class GitStats
---@field additions integer
---@field deletions integer

---@class FileEntry
---@field path string
---@field oldpath string
---@field parent_path string
---@field basename string
---@field extension string
---@field status string
---@field stats GitStats
---@field left_binary boolean|nil
---@field right_binary boolean|nil
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
    parent_path = utils.path_parent(opt.path, true) or "",
    basename = utils.path_basename(opt.path),
    extension = utils.path_extension(opt.path),
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
  if not config.get_config().diff_binaries then
    if self.left_binary == nil then
      local git = require'diffview.git'
      self.left_binary = git.is_binary(git_root, self.path, self.left)
      self.right_binary = git.is_binary(git_root, self.path, self.right)
    end
  end

  local splits = {
    {
      winid = left_winid, bufid = self.left_bufid,
      rev = self.left, pos = "left", binary = self.left_binary == true
    },
    {
      winid = right_winid, bufid = self.right_bufid,
      rev = self.right, pos = "right", binary = self.right_binary == true
    }
  }

  local last_winid = a.nvim_get_current_win()

  for _, split in ipairs(splits) do
    a.nvim_set_current_win(split.winid)

    if not (split.bufid and a.nvim_buf_is_loaded(split.bufid)) then
      if split.rev.type == RevType.LOCAL then

        if split.binary or M.should_null(split.rev, self.status, split.pos) then
          local bn = M._create_buffer(git_root, split.rev, self.path, true)
          table.insert(self.created_bufs, bn)
          a.nvim_win_set_buf(split.winid, bn)
          split.bufid = bn
        else
          vim.cmd("e " .. vim.fn.fnameescape(self.path))
          split.bufid = a.nvim_get_current_buf()
        end

      elseif split.rev.type == RevType.COMMIT then
        local bn
        if self.oldpath then
          bn = M._create_buffer(git_root, split.rev, self.oldpath, false)
        else
          bn = M._create_buffer(
            git_root, split.rev, self.path,
            split.binary or M.should_null(split.rev, self.status, split.pos)
          )
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
  a.nvim_set_current_win(last_winid)
end

function FileEntry:attach_buffers()
  if self.left_bufid then M._attach_buffer(self.left_bufid) end
  if self.right_bufid then M._attach_buffer(self.right_bufid) end
end

function FileEntry:detach_buffers()
  if self.left_bufid then M._detach_buffer(self.left_bufid) end
  if self.right_bufid then M._detach_buffer(self.right_bufid) end
end

---Compare against another FileEntry.
---@param other FileEntry
---@return boolean
function FileEntry:compare(other)
  if self.stats and not other.stats then return false end
  if not self.stats and other.stats then return false end
  if self.stats and other.stats then
    if (self.stats.additions ~= other.stats.additions
        or self.stats.deletions ~= other.stats.deletions) then
      return false
    end
  end

  return (
    self.path == other.path
    and self.status == other.status
    )
end

---Get the bufid of the null buffer. Create it if it's not loaded.
---@return integer
function M._get_null_buffer()
  if not (M._null_buffer and a.nvim_buf_is_loaded(M._null_buffer)) then
    local bn = a.nvim_create_buf(false, false)
    local bufname = utils.path_join({"diffview", "null"})
    a.nvim_buf_set_option(bn, "modified", false)
    a.nvim_buf_set_option(bn, "modifiable", false)

    local ok = pcall(a.nvim_buf_set_name, bn, bufname)
    if not ok then
      utils.wipe_named_buffer(bufname)
      a.nvim_buf_set_name(bn, bufname)
    end

    M._null_buffer = bn
  end

  return M._null_buffer
end

function M._create_buffer(git_root, rev, path, null)
  if null then return M._get_null_buffer() end

  local bn = a.nvim_create_buf(false, false)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " show " .. rev.commit .. ":" .. vim.fn.shellescape(path)
  local lines = vim.fn.systemlist(cmd)
  a.nvim_buf_set_lines(bn, 0, -1, false, lines)

  local basename = utils.path_basename(path)
  local bufname = basename
  if rev.type == RevType.COMMIT then
    local commit_abbrev = rev.commit:sub(1,7)
    bufname = commit_abbrev .. "_" .. basename
  end
  local fullname = utils.path_join({"diffview", bufname})
  a.nvim_buf_set_option(bn, "modified", false)
  a.nvim_buf_set_option(bn, "modifiable", false)

  local ok = pcall(a.nvim_buf_set_name, bn, fullname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    while not ok do
      fullname = utils.path_join({"diffview", i .. "_" .. bufname})
      ok = pcall(a.nvim_buf_set_name, bn, fullname)
      i = i + 1
    end
  end

  return bn
end

---Determine whether or not to create a "null buffer". Needed when the file
---doesn't exist for a given rev.
---@param rev Rev
---@param status string
---@param pos string
---@return boolean
function M.should_null(rev, status, pos)
  if rev.type == RevType.LOCAL then
    return status == "D"
  elseif rev.type == RevType.COMMIT then
    return (
      vim.tbl_contains({ "?", "A" }, status)
      and pos == "left"
    )
  end
end

function M.load_null_buffer(winid)
  local bn = M._get_null_buffer()
  a.nvim_win_set_buf(winid, bn)
  M._attach_buffer(bn)
end

function M._update_windows(left_winid, right_winid)
  for _, id in ipairs({ left_winid, right_winid }) do
    for k, v in pairs(FileEntry.winopts) do
      a.nvim_win_set_option(id, k, v)
    end
  end

  -- Scroll to trigger the scrollbind and sync the windows. This works more
  -- consistently than calling `:syncbind`.
  vim.cmd([[exec "normal! \<c-y>"]])
end

function M._attach_buffer(bufid)
  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings.view) do
    a.nvim_buf_set_keymap(bufid, "n", lhs, rhs, { noremap = true, silent = true })
  end
end

function M._detach_buffer(bufid)
  local conf = config.get_config()
  for lhs, _ in pairs(conf.key_bindings.view) do
    pcall(a.nvim_buf_del_keymap, bufid, "n", lhs)
  end
end

M.FileEntry = FileEntry

return M
