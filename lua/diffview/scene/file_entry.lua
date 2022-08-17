local File = require("diffview.git.file").File
local RevType = require("diffview.git.rev").RevType
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer

---@class FileEntry : diffview.Object
---@field git_ctx GitContext
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind git.FileKind
---@field commit Commit|nil
---@field active boolean
local FileEntry = oop.create_class("FileEntry")

---@class FileEntry.init.Opt
---@field git_ctx GitContext
---@field path string
---@field oldpath string
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind git.FileKind
---@field commit? Commit

---FileEntry constructor
---@param opt FileEntry.init.Opt
function FileEntry:init(opt)
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = utils.path:absolute(opt.path, opt.git_ctx.toplevel)
  self.parent_path = utils.path:parent(opt.path) or ""
  self.basename = utils.path:basename(opt.path)
  self.extension = utils.path:extension(opt.path)
  self.layout = opt.layout
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.commit = opt.commit
  self.active = false
end

function FileEntry:destroy()
  for _, f in ipairs(self.layout:files()) do
    f:destroy()
  end

  self.layout:destroy()
end

---@param new_head Rev
function FileEntry:update_heads(new_head)
  for _, file in ipairs(self.layout:files()) do
    if file.rev.track_head then
      file:dispose_buffer()
      file.rev = new_head
    end
  end
end

---@param flag boolean
function FileEntry:set_active(flag)
  self.active = flag

  for _, f in ipairs(self.layout:files()) do
    f.active = flag
  end
end

---@param git_ctx GitContext
---@param stat? table
function FileEntry:validate_stage_buffers(git_ctx, stat)
  stat = stat or utils.path:stat(utils.path:join(git_ctx.dir, "index"))
  local cached_stat = utils.tbl_access(fstat_cache, { git_ctx.toplevel, "index" })

  if stat then
    if not cached_stat or cached_stat.mtime < stat.mtime.sec then
      for _, f in ipairs(self.layout:files()) do
        if f.rev.type == RevType.STAGE then
          f:dispose_buffer()
        end
      end
    end
  end
end

---@static
---@param git_ctx GitContext
function FileEntry.update_index_stat(git_ctx, stat)
  stat = stat or utils.path:stat(utils.path:join(git_ctx.toplevel, "index"))

  if stat then
    if not fstat_cache[git_ctx.toplevel] then
      fstat_cache[git_ctx.toplevel] = {}
    end

    fstat_cache[git_ctx.toplevel].index = {
      mtime = stat.mtime.sec,
    }
  end
end

---@class FileEntry.from_d2.Opt : FileEntry.init.Opt
---@field rev_a Rev
---@field rev_b Rev
---@field nulled boolean
---@field get_data git.FileDataProducer?

---Create a file entry for a 2-way split diff layout.
---@param layout_class Layout (class)
---@param opt FileEntry.from_d2.Opt
---@return FileEntry
function FileEntry.for_d2(layout_class, opt)
  return FileEntry({
    git_ctx = opt.git_ctx,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    layout = layout_class({
      a = File({
        git_ctx = opt.git_ctx,
        path = opt.oldpath or opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_a,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_a, opt.status, "a")),
      }),
      b = File({
        git_ctx = opt.git_ctx,
        path = opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_b,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_b, opt.status, "b")),
      }),
    }),
  })
end

M.FileEntry = FileEntry
return M
