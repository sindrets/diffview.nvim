local utils = require'diffview.utils'
local FileEntry = require'diffview.file-entry'.FileEntry
local RevType = require'diffview.rev'.RevType

local a = vim.api

local M = {}

---@class CFileEntry
---@field left_data string[]
---@field right_data string[]
---@field left_null boolean
---@field right_null boolean
---INHERITED:
---@field path string
---@field oldpath string
---@field absolute_path string
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
---STATIC-INTERFACE:
---@field _null_buffer integer|nil
---@field _get_null_buffer function
---@field _create_buffer function
---@field should_null function
---@field load_null_buffer function
---@field _update_windows function
---@field _attach_buffer function
---@field _detach_buffer function
local CFileEntry = utils.class(FileEntry)

---CFileEntry constructor.
---@param opt any
---@return CFileEntry
function CFileEntry:new(opt)
  local this = {
    path = opt.path,
    oldpath = opt.oldpath,
    absolute_path = opt.absolute_path,
    parent_path = utils.path_parent(opt.path, true) or "",
    basename = utils.path_basename(opt.path),
    extension = utils.path_extension(opt.path),
    status = opt.status,
    stats = opt.stats,
    left = opt.left,
    right = opt.right,
    left_binary = opt.left_binary,
    right_binary = opt.right_binary,
    left_null = opt.left_null,
    right_null = opt.right_null,
    left_data = opt.left_data,
    right_data = opt.right_data,
    created_bufs = {}
  }
  setmetatable(this, self)
  return this
end

---@override
function CFileEntry:load_buffers(_, left_winid, right_winid)
  local splits = {
    {
      winid = left_winid, bufid = self.left_bufid, lines = self.left_data,
      rev = self.left, pos = "left", null = self.left_null == true
    },
    {
      winid = right_winid, bufid = self.right_bufid, lines = self.right_data,
      rev = self.right, pos = "right", null = self.right_null == true
    }
  }

  local last_winid = a.nvim_get_current_win()

  for _, split in ipairs(splits) do
    a.nvim_set_current_win(split.winid)

    if not (split.bufid and a.nvim_buf_is_loaded(split.bufid)) then
      if split.rev.type == RevType.LOCAL then

        if split.null or CFileEntry.should_null(split.rev, self.status, split.pos) then
          local bn = CFileEntry._create_buffer(nil ,split.rev, self.path, split.lines, true)
          a.nvim_win_set_buf(split.winid, bn)
          split.bufid = bn
        else
          vim.cmd("e " .. vim.fn.fnameescape(self.absolute_path))
          split.bufid = a.nvim_get_current_buf()
        end

      elseif split.rev.type == RevType.COMMIT or split.rev.type == RevType.CUSTOM then
        local bn
        if self.oldpath then
          bn = CFileEntry._create_buffer(nil, split.rev, self.oldpath, split.lines, false)
        else
          bn = CFileEntry._create_buffer(
            nil, split.rev, self.path, split.lines,
            split.null or CFileEntry.should_null(split.rev, self.status, split.pos)
          )
        end
        table.insert(self.created_bufs, bn)
        a.nvim_win_set_buf(split.winid, bn)
        split.bufid = bn
        vim.cmd("filetype detect")
      end

      CFileEntry._attach_buffer(split.bufid)
    else
      a.nvim_win_set_buf(split.winid, split.bufid)
      CFileEntry._attach_buffer(split.bufid)
    end
  end

  self.left_bufid = splits[1].bufid
  self.right_bufid = splits[2].bufid

  CFileEntry._update_windows(left_winid, right_winid)
  a.nvim_set_current_win(last_winid)
end

---@static
---@override
function CFileEntry._create_buffer(_, rev, path, lines, null)
  if null or not lines then return CFileEntry._get_null_buffer() end

  local bn = a.nvim_create_buf(false, false)
  a.nvim_buf_set_lines(bn, 0, -1, false, lines)

  local basename = utils.path_basename(path)
  local bufname = basename
  if rev.type == RevType.COMMIT then
    bufname = rev:abbrev() .. "_" .. basename
  elseif rev.type == RevType.CUSTOM then
    bufname = "[diff]_" .. basename
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

M.CFileEntry = CFileEntry
return M
