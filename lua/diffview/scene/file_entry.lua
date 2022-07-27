local File = require("diffview.git.file").File
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

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

---@class FileEntry.from_d2.Opt : FileEntry.init.Opt
---@field rev_a Rev
---@field rev_b Rev
---@field nulled boolean

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
        rev = opt.rev_a,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_a, opt.status, "a")),
      }),
      b = File({
        git_ctx = opt.git_ctx,
        path = opt.path,
        kind = opt.kind,
        commit = opt.commit,
        rev = opt.rev_b,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_b, opt.status, "b")),
      }),
    }),
  })
end

M.FileEntry = FileEntry
return M
