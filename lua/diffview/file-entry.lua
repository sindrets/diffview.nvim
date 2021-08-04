local oop = require'diffview.oop'
local utils = require'diffview.utils'
local config = require'diffview.config'
local RevType = require'diffview.rev'.RevType
local a = vim.api
local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer

---@class FileEntry
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field status string
---@field stats GitStats
---@field kind "working"|"staged"
---@field left_binary boolean|nil
---@field right_binary boolean|nil
---@field left Rev
---@field right Rev
---@field left_bufid integer
---@field right_bufid integer
---@field created_bufs integer[]
---STATIC-INTERFACE:
---@field _null_buffer integer|nil
---@field _get_null_buffer function
---@field _create_buffer function
---@field should_null function
---@field load_null_buffer function
---@field _update_windows function
---@field _attach_buffer function
---@field _detach_buffer function
local FileEntry = oop.create_class("FileEntry")

---@static
---@type integer|nil
FileEntry._null_buffer = nil

---@static
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
function FileEntry:init(opt)
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = opt.absolute_path
  self.parent_path = utils.path_parent(opt.path, true) or ""
  self.basename = utils.path_basename(opt.path)
  self.extension = utils.path_extension(opt.path)
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.left = opt.left
  self.right = opt.right
  self.created_bufs = {}
end

function FileEntry:destroy()
  self:detach_buffers()
  for _, bn in ipairs(self.created_bufs) do
    FileEntry.safe_delete_buf(bn)
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
      self.left_binary = git.is_binary(git_root, self.oldpath or self.path, self.left)
      self.right_binary = git.is_binary(git_root, self.path, self.right)
    end
  end

  local last_winid = a.nvim_get_current_win()
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

  for _, split in ipairs(splits) do
    local winnr = vim.fn.win_id2win(split.winid)

    if not (split.bufid and a.nvim_buf_is_loaded(split.bufid)) then
      if split.rev.type == RevType.LOCAL then

        if split.binary or FileEntry.should_null(split.rev, self.status, split.pos) then
          local bn = FileEntry._create_buffer(git_root, split.rev, self.path, true)
          a.nvim_win_set_buf(split.winid, bn)
          split.bufid = bn
        else
          vim.cmd(winnr .. "windo edit " .. vim.fn.fnameescape(self.absolute_path))
          split.bufid = a.nvim_get_current_buf()
        end

      elseif split.rev.type == RevType.COMMIT or split.rev.type == RevType.INDEX then
        local bn
        if self.oldpath and split.pos == "left" then
          bn = FileEntry._create_buffer(git_root, split.rev, self.oldpath, split.binary)
        else
          bn = FileEntry._create_buffer(
            git_root, split.rev, self.path,
            split.binary or FileEntry.should_null(split.rev, self.status, split.pos)
          )
        end
        table.insert(self.created_bufs, bn)
        a.nvim_win_set_buf(split.winid, bn)
        split.bufid = bn
        vim.cmd(winnr .. "windo filetype detect")
      end

      FileEntry._attach_buffer(split.bufid)
    else
      a.nvim_win_set_buf(split.winid, split.bufid)
      FileEntry._attach_buffer(split.bufid)
    end
  end

  self.left_bufid = splits[1].bufid
  self.right_bufid = splits[2].bufid

  FileEntry._update_windows(left_winid, right_winid)
  a.nvim_set_current_win(last_winid)
end

function FileEntry:attach_buffers()
  if self.left_bufid then FileEntry._attach_buffer(self.left_bufid) end
  if self.right_bufid then FileEntry._attach_buffer(self.right_bufid) end
end

function FileEntry:detach_buffers()
  if self.left_bufid then FileEntry._detach_buffer(self.left_bufid) end
  if self.right_bufid then FileEntry._detach_buffer(self.right_bufid) end
end

---@param split "left"|"right"
function FileEntry:dispose_buffer(split)
  if vim.tbl_contains({ "left", "right" }, split) then
    local bufid = self[split .. "_bufid"]
    if bufid and a.nvim_buf_is_loaded(bufid) then
      FileEntry._detach_buffer(bufid)
      FileEntry.safe_delete_buf(bufid)
      self[split .. "_bufid"] = nil
    end
  end
end

function FileEntry:dispose_index_buffers()
  for _, split in ipairs({ "left", "right" }) do
    if self[split].type == RevType.INDEX then
      self:dispose_buffer(split)
    end
  end
end

function FileEntry:validate_index_buffers(git_root, git_dir, stat)
  stat = stat or vim.loop.fs_stat(utils.path_join({ git_dir, "index" }))
  local cached_stat
  if fstat_cache[git_root] then
    cached_stat = fstat_cache[git_root].index
  end

  if stat then
    if not cached_stat or cached_stat.mtime < stat.mtime.sec then
      self:dispose_index_buffers()
    end
  end
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

---@static Get the bufid of the null buffer. Create it if it's not loaded.
---@return integer
function FileEntry._get_null_buffer()
  if not (FileEntry._null_buffer and a.nvim_buf_is_loaded(FileEntry._null_buffer)) then
    local bn = a.nvim_create_buf(false, false)
    local bufname = utils.path_join({"diffview", "null"})
    a.nvim_buf_set_option(bn, "modified", false)
    a.nvim_buf_set_option(bn, "modifiable", false)

    local ok = pcall(a.nvim_buf_set_name, bn, bufname)
    if not ok then
      utils.wipe_named_buffer(bufname)
      a.nvim_buf_set_name(bn, bufname)
    end

    FileEntry._null_buffer = bn
  end

  return FileEntry._null_buffer
end

---@static
---@param git_root string
---@param rev Rev
---@param path string
---@param null boolean
function FileEntry._create_buffer(git_root, rev, path, null)
  if null then return FileEntry._get_null_buffer() end

  local bn = a.nvim_create_buf(false, false)
  local cmd = "git -C " .. vim.fn.shellescape(git_root) .. " show " .. (rev.commit or "") .. ":" .. vim.fn.shellescape(path)
  local lines = vim.fn.systemlist(cmd)
  a.nvim_buf_set_lines(bn, 0, -1, false, lines)

  local basename = utils.path_basename(path)
  local bufname = basename
  if rev.type == RevType.COMMIT then
    bufname = rev:abbrev() .. "_" .. basename
  elseif rev.type == RevType.INDEX then
    bufname = "[index]_" .. basename
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

---@static Determine whether or not to create a "null buffer". Needed when the file
---doesn't exist for a given rev.
---@param rev Rev
---@param status string
---@param pos string
---@return boolean
function FileEntry.should_null(rev, status, pos)
  if rev.type == RevType.LOCAL then
    return status == "D"
  elseif rev.type == RevType.COMMIT then
    return (
      vim.tbl_contains({ "?", "A" }, status)
      and pos == "left"
    )
  end
end

---@static
function FileEntry.load_null_buffer(winid)
  local bn = FileEntry._get_null_buffer()
  a.nvim_win_set_buf(winid, bn)
  FileEntry._attach_buffer(bn)
end

---@static
function FileEntry.safe_delete_buf(bufid)
  if bufid == FileEntry._null_buffer then return end
  for _, winid in ipairs(utils.tabpage_win_find_buf(0, bufid)) do
    FileEntry.load_null_buffer(winid)
  end
  pcall(a.nvim_buf_delete, bufid, { force = true })
end

---@static
function FileEntry._update_windows(left_winid, right_winid)
  for _, id in ipairs({ left_winid, right_winid }) do
    for k, v in pairs(FileEntry.winopts) do
      a.nvim_win_set_option(id, k, v)
    end
  end

  -- Scroll to trigger the scrollbind and sync the windows. This works more
  -- consistently than calling `:syncbind`.
  vim.cmd([[exec "normal! \<c-y>"]])
end

---@static
function FileEntry._attach_buffer(bufid)
  local conf = config.get_config()
  for lhs, rhs in pairs(conf.key_bindings.view) do
    a.nvim_buf_set_keymap(bufid, "n", lhs, rhs, { noremap = true, silent = true })
  end
end

---@static
function FileEntry._detach_buffer(bufid)
  local conf = config.get_config()
  for lhs, _ in pairs(conf.key_bindings.view) do
    pcall(a.nvim_buf_del_keymap, bufid, "n", lhs)
  end
end

---@static
function FileEntry.update_index_stat(git_root, git_dir, stat)
  stat = stat or vim.loop.fs_stat(utils.path_join({ git_dir, "index" }))
  if stat then
    if not fstat_cache[git_root] then fstat_cache[git_root] = {} end
    fstat_cache[git_root].index = {
      mtime = stat.mtime.sec
    }
  end
end

M.FileEntry = FileEntry

return M
