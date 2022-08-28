local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

---@type git.File|LazyModule
local File = lazy.access("diffview.git.file", "File")
---@type RevType|LazyModule
local RevType = lazy.access("diffview.git.rev", "RevType")
---@type Diff1|LazyModule
local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1")
---@type Diff2|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2")
---@type Diff3|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3")
---@type Diff4|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

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

---@param target_layout Layout
function FileEntry:convert_layout(target_layout)
    local cur_layout = self.layout

    if cur_layout:class() == target_layout:class() then return end

    if cur_layout:instanceof(Diff1.__get()) then
      ---@cast cur_layout Diff1
      if target_layout:instanceof(Diff3.__get()) then
        ---@cast target_layout Diff3
        self.layout = cur_layout:to_diff3(target_layout)
        return
      elseif target_layout:instanceof(Diff4.__get()) then
        ---@cast target_layout Diff4
        self.layout = cur_layout:to_diff4(target_layout)
        return
      end
    elseif cur_layout:instanceof(Diff2.__get()) then
      ---@cast cur_layout Diff2
      if target_layout:instanceof(Diff2.__get()) then
        self.layout = target_layout({
          a = cur_layout.a.file,
          b = cur_layout.b.file,
        })
        return
      end
    elseif cur_layout:instanceof(Diff3.__get()) then
      ---@cast cur_layout Diff3
      if target_layout:instanceof(Diff1.__get()) then
        ---@cast target_layout Diff1
        self.layout = cur_layout:to_diff1(target_layout)
        return
      elseif target_layout:instanceof(Diff3.__get()) then
        self.layout = target_layout({
          a = cur_layout.a.file,
          b = cur_layout.b.file,
          c = cur_layout.c.file,
        })
        return
      elseif target_layout:instanceof(Diff4.__get()) then
        ---@cast target_layout Diff4
        self.layout = cur_layout:to_diff4(target_layout)
        return
      end
    elseif cur_layout:instanceof(Diff4.__get()) then
      ---@cast cur_layout Diff4
      if target_layout:instanceof(Diff1.__get()) then
        ---@cast target_layout Diff1
        self.layout = cur_layout:to_diff1(target_layout)
        return
      elseif target_layout:instanceof(Diff4.__get()) then
        self.layout = target_layout({
          a = cur_layout.a.file,
          b = cur_layout.b.file,
          c = cur_layout.c.file,
          d = cur_layout.d.file,
        })
        return
      elseif target_layout:instanceof(Diff3.__get()) then
        ---@cast target_layout Diff3
        self.layout = cur_layout:to_diff3(target_layout)
        return
      end
    end

    error(("Unimplemented layout conversion: %s to %s"):format(
      cur_layout:class(),
      target_layout:class()
    ))
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
---@param layout_class Diff2 (class)
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

---@class FileEntry.from_d3.Opt : FileEntry.init.Opt
---@field rev_a Rev
---@field rev_b Rev
---@field rev_c Rev
---@field nulled boolean
---@field get_data git.FileDataProducer?

---Create a file entry for a 2-way split diff layout.
---@param layout_class Diff3 (class)
---@param opt FileEntry.from_d3.Opt
---@return FileEntry
function FileEntry.for_d3(layout_class, opt)
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
      c = File({
        git_ctx = opt.git_ctx,
        path = opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_c,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_c, opt.status, "c")),
      }),
    }),
  })
end

---@class FileEntry.with_layout.Opt : FileEntry.init.Opt
---@field rev_main Rev
---@field rev_ours Rev
---@field rev_theirs Rev
---@field rev_base Rev
---@field nulled boolean
---@field get_data git.FileDataProducer?

---@param layout_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return FileEntry
function FileEntry.with_layout(layout_class, opt)
  local new_layout
  local main_file = File({
    git_ctx = opt.git_ctx,
    path = opt.path,
    kind = opt.kind,
    commit = opt.commit,
    get_data = opt.get_data,
    rev = opt.rev_main,
  }) --[[@as git.File ]]

  if layout_class:instanceof(Diff1.__get()) then
    main_file.nulled = layout_class.should_null(main_file.rev, opt.status, "a")
    new_layout = layout_class({
      a = main_file,
    })
  else
    main_file.nulled = layout_class.should_null(main_file.rev, opt.status, "b")
    new_layout = layout_class({
      a = File({
        git_ctx = opt.git_ctx,
        path = opt.oldpath or opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_ours,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_ours, opt.status, "a")),
      }),
      b = main_file,
      c = File({
        git_ctx = opt.git_ctx,
        path = opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_theirs,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_theirs, opt.status, "c")),
      }),
      d = File({
        git_ctx = opt.git_ctx,
        path = opt.path,
        kind = opt.kind,
        commit = opt.commit,
        get_data = opt.get_data,
        rev = opt.rev_base,
        nulled = utils.sate(opt.nulled, layout_class.should_null(opt.rev_base, opt.status, "d")),
      }),
    })
  end

  return FileEntry({
    git_ctx = opt.git_ctx,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    layout = new_layout,
  })
end

M.FileEntry = FileEntry
return M
