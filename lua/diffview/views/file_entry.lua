local oop = require("diffview.oop")
local utils = require("diffview.utils")
local config = require("diffview.config")
local logger = require("diffview.logger")
local RevType = require("diffview.git.rev").RevType
local PerfTimer = require("diffview.perf").PerfTimer
local api = vim.api
local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer

---@class FileEntry : Object
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field status string
---@field stats GitStats
---@field kind '"working"'|'"staged"'
---@field commit Commit|nil
---@field active boolean
---@field left Rev
---@field right Rev
---@field left_binary boolean|nil
---@field right_binary boolean|nil
---@field left_bufid integer
---@field right_bufid integer
---@field left_ready boolean
---@field right_ready boolean
---@field created_bufs integer[]
local FileEntry = oop.create_class("FileEntry")

---@static
---@type integer|nil
FileEntry._null_buffer = nil

---@static
---@type table<integer, table>
FileEntry.winopt_store = {}

---@static
FileEntry.winopts = {
  diff = true,
  scrollbind = true,
  cursorbind = true,
  scrollopt = { "ver", "hor", "jump" },
  foldmethod = "diff",
  foldcolumn = "1",
  foldlevel = 0,
}

FileEntry.bufopts = {
  buftype = "nofile",
  modifiable = false,
  swapfile = false,
  bufhidden = "hide",
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
  self.commit = opt.commit
  self.active = false
  self.left = opt.left
  self.right = opt.right
  self.left_ready = false
  self.right_ready = true
  self.created_bufs = {}
end

function FileEntry:destroy()
  self.active = false
  self:detach_buffers()
  self:restore_winopts()
  for _, bn in ipairs(self.created_bufs) do
    FileEntry.safe_delete_buf(bn)
  end
end

---Load the buffers.
---@param git_root string
---@param left_winid integer
---@param right_winid integer
---@param callback function
function FileEntry:load_buffers(git_root, left_winid, right_winid, callback)
  ---@type PerfTimer
  local perf = PerfTimer("[FileEntry] Buffer load")

  if not config.get_config().diff_binaries then
    if self.left_binary == nil then
      local git = require("diffview.git.utils")
      self.left_binary = git.is_binary(git_root, self.oldpath or self.path, self.left)
      self.right_binary = git.is_binary(git_root, self.path, self.right)
      perf:lap("binary check")
    end
  end

  local splits = {
    {
      winid = left_winid,
      bufid = self.left_bufid,
      rev = self.left,
      pos = "left",
      binary = self.left_binary == true,
      ready = false,
    },
    {
      winid = right_winid,
      bufid = self.right_bufid,
      rev = self.right,
      pos = "right",
      binary = self.right_binary == true,
      ready = false,
    },
  }

  local function on_ready_factory(split)
    return function()
      split.ready = true
      self[split.pos .. "_ready"] = true
      if splits[1].ready and splits[2].ready and self.active then
        perf:lap("both buffers ready")
        for _, sp in ipairs(splits) do
          if sp.load then
            sp.load()
          else
            api.nvim_win_set_buf(sp.winid, sp.bufid)
          end
          if sp.rev.type == RevType.LOCAL and not FileEntry.winopt_store[sp.bufid] then
            FileEntry._save_winopts(sp.bufid, sp.winid)
          end
        end
        FileEntry._update_windows(left_winid, right_winid)
        perf:lap("view updated")
        perf:time()
        logger.lvl(5).s_debug(perf)
        if type(callback) == "function" then
          callback()
        end
      end
    end
  end

  self.left_ready = self.left_bufid and api.nvim_buf_is_loaded(self.left_bufid)
  self.right_ready = self.right_bufid and api.nvim_buf_is_loaded(self.right_bufid)

  if not (self.left_ready and self.right_ready) then
    utils.no_win_event_call(function()
      FileEntry.load_null_buffer(left_winid)
      FileEntry.load_null_buffer(right_winid)
    end)
    perf:lap("null buffers loaded")
  end

  utils.no_win_event_call(function()
    for _, split in ipairs(splits) do
      local on_ready = on_ready_factory(split)

      if not (split.bufid and api.nvim_buf_is_loaded(split.bufid)) then
        if split.rev.type == RevType.LOCAL then
          if split.binary or FileEntry.should_null(split.rev, self.status, split.pos) then
            local bn = FileEntry._create_buffer(git_root, split.rev, self.path, true, on_ready)
            split.bufid = bn
            FileEntry._attach_buffer(split.bufid)
          else
            -- Load local file
            split.load = function()
              api.nvim_win_call(split.winid, function()
                vim.cmd("edit " .. vim.fn.fnameescape(self.absolute_path))
                split.bufid = api.nvim_get_current_buf()
                self[split.pos .. "_bufid"] = split.bufid
                FileEntry._attach_buffer(split.bufid)
                perf:lap("edit call")
              end)
            end
            on_ready()
          end
        elseif split.rev.type == RevType.COMMIT or split.rev.type == RevType.INDEX then
          -- Create file from git
          local bn
          if self.oldpath and split.pos == "left" then
            bn = FileEntry._create_buffer(
              git_root, split.rev, self.oldpath, split.binary, on_ready
            )
          else
            bn = FileEntry._create_buffer(
              git_root,
              split.rev,
              self.path,
              split.binary or FileEntry.should_null(split.rev, self.status, split.pos),
              on_ready
            )
          end
          table.insert(self.created_bufs, bn)
          split.bufid = bn

          FileEntry._attach_buffer(split.bufid)
        end
      else
        -- Buffer already exists
        FileEntry._attach_buffer(split.bufid)
        on_ready()
      end
      perf:lap("split done")
    end
  end)

  perf:lap("buffers attached")

  self.left_bufid = splits[1].bufid
  self.right_bufid = splits[2].bufid
  vim.cmd("do WinEnter")

  perf:lap("load done")
end

function FileEntry:attach_buffers()
  if self.left_bufid then
    FileEntry._attach_buffer(self.left_bufid)
  end
  if self.right_bufid then
    FileEntry._attach_buffer(self.right_bufid)
  end
end

function FileEntry:detach_buffers()
  if self.left_bufid then
    FileEntry._detach_buffer(self.left_bufid)
  end
  if self.right_bufid then
    FileEntry._detach_buffer(self.right_bufid)
  end
end

---@param split "left"|"right"
function FileEntry:dispose_buffer(split)
  if vim.tbl_contains({ "left", "right" }, split) then
    local bufid = self[split .. "_bufid"]
    if bufid and api.nvim_buf_is_loaded(bufid) then
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
  if self.stats and not other.stats then
    return false
  end
  if not self.stats and other.stats then
    return false
  end
  if self.stats and other.stats then
    if
      self.stats.additions ~= other.stats.additions
      or self.stats.deletions ~= other.stats.deletions
    then
      return false
    end
  end

  return (self.path == other.path and self.status == other.status)
end

function FileEntry:restore_winopts()
  for _, bufid in ipairs({ self.left_bufid, self.right_bufid }) do
    if bufid then
      FileEntry._restore_winopts(bufid)
    end
  end
end

---@static Get the bufid of the null buffer. Create it if it's not loaded.
---@return integer
function FileEntry._get_null_buffer()
  if not (FileEntry._null_buffer and api.nvim_buf_is_loaded(FileEntry._null_buffer)) then
    local bn = api.nvim_create_buf(false, false)
    local bufname = utils.path_join({ "diffview://", "null" })
    for option, value in pairs(FileEntry.bufopts) do
      api.nvim_buf_set_option(bn, option, value)
    end

    local ok = pcall(api.nvim_buf_set_name, bn, bufname)
    if not ok then
      utils.wipe_named_buffer(bufname)
      api.nvim_buf_set_name(bn, bufname)
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
---@param callback function
function FileEntry._create_buffer(git_root, rev, path, null, callback)
  if null then
    callback()
    return FileEntry._get_null_buffer()
  end

  local bn = api.nvim_create_buf(false, false)

  local context
  if rev.type == RevType.COMMIT then
    context = rev:abbrev()
  elseif rev.type == RevType.INDEX then
    context = ":0:"
  end

  -- stylua: ignore
  local fullname = utils.path_join({ "diffview://", git_root, ".git", context, path, })
  for option, value in pairs(FileEntry.bufopts) do
    api.nvim_buf_set_option(bn, option, value)
  end

  local ok = pcall(api.nvim_buf_set_name, bn, fullname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    repeat
      -- stylua: ignore
      fullname = utils.path_join({ "diffview://", git_root, ".git", context, i, path, })
      ok = pcall(api.nvim_buf_set_name, bn, fullname)
      i = i + 1
    until ok
  end

  local git = require("diffview.git.utils")
  git.show(git_root, { (rev.commit or "") .. ":" .. path }, function(err, result)
    if not err then
      vim.schedule(function()
        if api.nvim_buf_is_valid(bn) then
          vim.bo[bn].modifiable = true
          api.nvim_buf_set_lines(bn, 0, -1, false, result)
          vim.bo[bn].modifiable = false
          vim.api.nvim_buf_call(bn, function()
            vim.cmd("filetype detect")
          end)
          callback()
        end
      end)
    else
      logger.error("[git] Failed to show file content.")
      logger.error("[stderr] " .. table.concat(err, "\n"))
      utils.err(string.format("Failed to create diff buffer: '%s'", fullname), true)
    end
  end)

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
    return (vim.tbl_contains({ "?", "A" }, status) and pos == "left")
  end
end

---@static
function FileEntry.load_null_buffer(winid)
  local bn = FileEntry._get_null_buffer()
  api.nvim_win_set_buf(winid, bn)
  FileEntry._attach_buffer(bn)
end

---@static
function FileEntry.safe_delete_buf(bufid)
  if bufid == FileEntry._null_buffer then
    return
  end
  for _, winid in ipairs(utils.tabpage_win_find_buf(0, bufid)) do
    FileEntry.load_null_buffer(winid)
  end
  pcall(api.nvim_buf_delete, bufid, { force = true })
end

---@static
function FileEntry._save_winopts(bufid, winid)
  FileEntry.winopt_store[bufid] = {}
  api.nvim_win_call(winid, function()
    for option, _ in pairs(FileEntry.winopts) do
      FileEntry.winopt_store[bufid][option] = vim.o[option]
    end
  end)
end

---@static
function FileEntry._restore_winopts(bufid)
  if FileEntry.winopt_store[bufid] then
    utils.no_win_event_call(function()
      vim.cmd("sp")
      api.nvim_win_set_buf(0, bufid)
      utils.set_local(0, FileEntry.winopt_store[bufid])
      api.nvim_win_close(0, true)
    end)
  end
end

---@static
function FileEntry._update_windows(left_winid, right_winid)
  utils.set_local({ left_winid, right_winid }, FileEntry.winopts)

  local cur_winid = api.nvim_get_current_win()
  for _, id in ipairs({ left_winid, right_winid }) do
    if id ~= cur_winid then
      api.nvim_win_call(id, function()
        if id == right_winid then
          -- Scroll to trigger the scrollbind and sync the windows. This works more
          -- consistently than calling `:syncbind`.
          vim.cmd([[exe "norm! \<c-e>\<c-y>"]])
        end
        vim.cmd("do WinLeave")
      end)
    end
  end
end

---@static
function FileEntry._attach_buffer(bufid)
  local conf = config.get_config()
  local opt = { noremap = true, silent = true, nowait = true }
  for lhs, rhs in pairs(conf.key_bindings.view) do
    api.nvim_buf_set_keymap(bufid, "n", lhs, rhs, opt)
  end
end

---@static
function FileEntry._detach_buffer(bufid)
  local conf = config.get_config()
  for lhs, _ in pairs(conf.key_bindings.view) do
    pcall(api.nvim_buf_del_keymap, bufid, "n", lhs)
  end
end

---@static
function FileEntry.update_index_stat(git_root, git_dir, stat)
  stat = stat or vim.loop.fs_stat(utils.path_join({ git_dir, "index" }))
  if stat then
    if not fstat_cache[git_root] then
      fstat_cache[git_root] = {}
    end
    fstat_cache[git_root].index = {
      mtime = stat.mtime.sec,
    }
  end
end

M.FileEntry = FileEntry

return M
