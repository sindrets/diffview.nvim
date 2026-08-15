local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local Unified = lazy.access("diffview.scene.layouts.unified", "Unified") ---@type Unified|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local Rev = lazy.access("diffview.vcs.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local unified = lazy.require("diffview.vcs.unified") ---@module "diffview.vcs.unified"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local fmt = string.format
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer
---@field conflicts integer

---@class RevMap
---@field a Rev
---@field b Rev
---@field c Rev
---@field d Rev

---@class FileEntry : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit Commit|nil
---@field merge_ctx vcs.MergeContext?
---@field active boolean
---@field opened boolean
local FileEntry = oop.create_class("FileEntry")

---@class FileEntry.init.Opt
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit? Commit
---@field merge_ctx? vcs.MergeContext

---FileEntry constructor
---@param opt FileEntry.init.Opt
function FileEntry:init(opt)
  self.adapter = opt.adapter
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = pl:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path)
  self.revs = opt.revs
  self.layout = opt.layout
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.commit = opt.commit
  self.merge_ctx = opt.merge_ctx
  self.active = false
  self.opened = false
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

---Create the file that backs the unified view of this entry. Its content is
---produced on demand, and is the whole file with the removed lines spliced
---back in - see |diffview.vcs.unified|.
---@return vcs.File
function FileEntry:create_unified_file()
  local cached = self.kind == "staged"
  local file

  file = File({
    adapter = self.adapter,
    path = self.path,
    kind = self.kind,
    commit = self.commit,
    rev = Rev(RevType.CUSTOM),
    nulled = false,
    get_data = function()
      local data = unified.build(self.adapter, self.path, {
        cached = cached,
        untracked = self.status == "?",
        absolute_path = self.absolute_path,
      })

      file.unified_data = data

      if not data then
        file.custom_folds = nil
        return { "" }
      end

      local folds = { type = "unified" }
      for i, fold in ipairs(data.folds) do folds[i] = fold end
      file.custom_folds = folds

      return data.lines
    end,
    winopts = {
      diff = false,
      scrollbind = false,
      cursorbind = false,
      foldmethod = "manual",
      foldcolumn = "1",
      foldlevel = 0,
      foldenable = true,
      winhl = {
        "DiffAdd:DiffviewDiffAdd",
        "DiffDelete:DiffviewDiffDelete",
        "DiffChange:DiffviewDiffChange",
        "DiffText:DiffviewDiffText",
      },
    },
  }) --[[@as vcs.File ]]

  -- Writing the inline buffer writes the new side of the diff: the working
  -- tree for unstaged changes, the index for staged ones. The removed lines
  -- are dropped - they aren't part of the file.
  file.write_handler = function(f)
    local data = f.unified_data

    if not data then return end

    if data.has_gap then
      utils.err(
        "This inline diff is too large to be shown in full, so it can't be written back. "
        .. "Use the side-by-side layout to edit this file."
      )
      return
    end

    local content = unified.new_side_content(f.bufnr)

    if cached then
      local ok, stderr = self.adapter:stage_content(self.path, content)

      if not ok then
        utils.err(utils.vec_join(fmt("Failed to stage '%s'!", self.path), stderr), true)
        return
      end
    else
      local target = utils.find_file_buffer(self.absolute_path)

      if target and vim.bo[target].modified then
        utils.err(fmt(
          "'%s' is open with unsaved changes! Write or discard those first.",
          self.path
        ))
        return
      end

      if vim.fn.writefile(content, self.absolute_path) ~= 0 then
        utils.err(fmt("Failed to write '%s'!", self.path))
        return
      end

      -- Pull the new content into any buffer that has the file open.
      if target then vim.cmd(fmt("checktime %d", target)) end
    end

    vim.bo[f.bufnr].modified = false
    self:reload_unified()

    api.nvim_exec_autocmds("BufWritePost", {
      pattern = api.nvim_buf_get_name(f.bufnr),
    })

    utils.info(fmt(
      "Wrote %d lines to %s.",
      #content,
      cached and ("the index for '" .. self.path .. "'") or ("'" .. self.path .. "'")
    ))
  end

  file.unified = true
  -- The content is generated: there's nothing to probe for binary-ness.
  file.binary = false
  file.custom_context = cached and "[unified:staged]" or "[unified]"
  file.winbar = (" INLINE DIFF - %s%s"):format(self.path, cached and " (staged)" or "")

  return file
end

---@param target_layout Layout
function FileEntry:convert_layout(target_layout)
  local from_unified = self.layout:instanceof(Unified.__get())

  if target_layout == Unified.__get() then
    self.layout = target_layout({ b = self:create_unified_file() })
    return
  end

  local get_data

  for _, file in ipairs(self.layout:files()) do
    -- The unified file produces content for a layout that no longer applies.
    if file.get_data and not file.unified then
      get_data = file.get_data
      break
    end
  end

  local function create_file(rev, symbol)
    return File({
      adapter = self.adapter,
      path = symbol == "a" and self.oldpath or self.path,
      kind = self.kind,
      commit = self.commit,
      get_data = get_data,
      rev = rev,
      nulled = select(2, pcall(target_layout.should_null, rev, self.status, symbol)),
    }) --[[@as vcs.File ]]
  end

  ---@param symbol string
  ---@return vcs.File?
  local function reuse(symbol)
    if from_unified then return nil end
    return utils.tbl_access(self.layout, symbol .. ".file")
  end

  self.layout = target_layout({
    a = reuse("a") or create_file(self.revs.a, "a"),
    b = reuse("b") or create_file(self.revs.b, "b"),
    c = reuse("c") or create_file(self.revs.c, "c"),
    d = reuse("d") or create_file(self.revs.d, "d"),
  })
  self:update_merge_context()
end

---Rebuild the content of the unified view, if that's the current layout.
function FileEntry:refresh_unified()
  if not self.layout:instanceof(Unified.__get()) then return end

  local file = self.layout:get_main_win().file
  if file then file:dispose_buffer() end
end

---Regenerate the content of the inline buffer in place, keeping the window on
---it. Used after the buffer has been written.
function FileEntry:reload_unified()
  if not self.layout:instanceof(Unified.__get()) then return end

  local file = self.layout:get_main_win().file

  if not (file and file.get_data and file:is_valid()) then return end

  -- NOTE: the entry's layout only carries the files - the windows that are
  -- actually on screen belong to the view's layout, so find them by buffer.
  local winid = vim.fn.win_findbuf(file.bufnr)[1]
  local cursor = winid and api.nvim_win_get_cursor(winid) or nil

  local lines = file.get_data()

  local was_modifiable = vim.bo[file.bufnr].modifiable
  vim.bo[file.bufnr].modifiable = true
  api.nvim_buf_set_lines(file.bufnr, 0, -1, false, lines)
  vim.bo[file.bufnr].modifiable = was_modifiable
  vim.bo[file.bufnr].modified = false

  unified.apply_highlights(file.bufnr, file.unified_data)

  if not winid then return end

  -- Replacing the content drops the folds: rebuild them.
  api.nvim_win_call(winid, function()
    if vim.wo.foldmethod == "manual" then
      pcall(vim.cmd, "norm! zE")

      for _, fold in ipairs(file.custom_folds or {}) do
        pcall(vim.cmd, fmt("%d,%dfold", fold[1], fold[2]))
      end
    end
  end)

  if cursor then
    pcall(api.nvim_win_set_cursor, winid, {
      math.min(cursor[1], api.nvim_buf_line_count(file.bufnr)),
      cursor[2],
    })
  end
end

---@param stat? table
function FileEntry:validate_stage_buffers(stat)
  stat = stat or pl:stat(pl:join(self.adapter.ctx.dir, "index"))
  local cached_stat = utils.tbl_access(fstat_cache, { self.adapter.ctx.toplevel, "index" })

  if stat and (not cached_stat or cached_stat.mtime < stat.mtime.sec) then
    for _, f in ipairs(self.layout:files()) do
      if f.rev.type == RevType.STAGE and f:is_valid() then
        if f.rev.stage > 0 then
          -- We only care about stage 0 here
          f:dispose_buffer()
        else
          local is_modified = vim.bo[f.bufnr].modified

          if f.blob_hash then
            local new_hash = self.adapter:file_blob_hash(f.path)

            if new_hash and new_hash ~= f.blob_hash then
              if is_modified then
                utils.warn((
                  "A file was changed in the index since you started editing it!"
                  .. " Be careful not to lose any staged changes when writing to this buffer: %s"
                ):format(api.nvim_buf_get_name(f.bufnr)))
              else
                f:dispose_buffer()
              end
            end
          elseif not is_modified then
            -- Should be very rare that we don't have an index-buffer's blob
            -- hash. But in that case, we can't warn the user when a file
            -- changes in the index while they're editing its index buffer.
            f:dispose_buffer()
          end
        end
      end
    end
  end
end

---Update winbar info
---@param ctx? vcs.MergeContext
function FileEntry:update_merge_context(ctx)
  ctx = ctx or self.merge_ctx
  if ctx then self.merge_ctx = ctx else return end

  local layout = self.layout --[[@as Diff4 ]]

  if layout.a then
    layout.a.file.winbar = (" OURS (Current changes) %s %s"):format(
      (ctx.ours.hash):sub(1, 10),
      ctx.ours.ref_names and ("(" .. ctx.ours.ref_names .. ")") or ""
    )
  end

  if layout.b then
    layout.b.file.winbar = " LOCAL (Working tree)"
  end

  if layout.c then
    layout.c.file.winbar = (" THEIRS (Incoming changes) %s %s"):format(
      (ctx.theirs.hash):sub(1, 10),
      ctx.theirs.ref_names and ("(" .. ctx.theirs.ref_names .. ")") or ""
    )
  end

  if layout.d then
    layout.d.file.winbar = (" BASE (Common ancestor) %s %s"):format(
      (ctx.base.hash):sub(1, 10),
      ctx.base.ref_names and ("(" .. ctx.base.ref_names .. ")") or ""
    )
  end
end

---Derive custom folds from the hunks in a diff patch.
---@param diff diff.FileEntry
function FileEntry:update_patch_folds(diff)
  if not self.layout:instanceof(Diff2.__get()) then return end

  local layout = self.layout --[[@as Diff2 ]]
  local folds = {
    a = utils.tbl_set(layout.a.file, { "custom_folds" }, { type = "diff_patch" }),
    b = utils.tbl_set(layout.b.file, { "custom_folds" }, { type = "diff_patch" }),
  }

  local lcount_a = api.nvim_buf_line_count(layout.a.file.bufnr)
  local lcount_b = api.nvim_buf_line_count(layout.b.file.bufnr)

  local prev_last_old, prev_last_new = 0, 0

  for i = 1, #diff.hunks + 1 do
    local hunk = diff.hunks[i]
    local first_old, last_old, first_new, last_new

    if hunk then
      first_old = hunk.old_row
      last_old = first_old + hunk.old_size - 1
      first_new = hunk.new_row
      last_new = first_new + hunk.new_size - 1
    else
      first_old = lcount_a + 1
      first_new = lcount_b + 1
    end

    if first_old - prev_last_old > 1 then
      local prev_fold = folds.a[#folds.a]

      if prev_fold and (prev_last_old + 1) - prev_fold[2] == 1 then
        -- This fold is right next to the previous: merge the folds
        prev_fold[2] = first_old - 1
      else
        table.insert(folds.a, { prev_last_old + 1, first_old - 1 })
      end
      -- print("old:", folds.a[#folds.a][1], folds.a[#folds.a][2])
    end

    if first_new - prev_last_new > 1 then
      local prev_fold = folds.b[#folds.b]

      if prev_fold and (prev_last_new + 1) - prev_fold[2] == 1 then
        -- This fold is right next to the previous: merge the folds
        prev_fold[2] = first_new - 1
      else
        table.insert(folds.b, { prev_last_new + 1, first_new - 1 })
      end
      -- print("new:", folds.b[#folds.b][1], folds.b[#folds.b][2])
    end

    prev_last_old = last_old
    prev_last_new = last_new
  end
end

---Check if the entry has custom diff patch folds.
---@return boolean
function FileEntry:has_patch_folds()
  for _, file in ipairs(self.layout:files()) do
    if not file.custom_folds or file.custom_folds.type ~= "diff_patch" then
      return false
    end
  end

  return true
end

---@return boolean
function FileEntry:is_null_entry()
  return self.path == "null" and self.layout:get_main_win().file == File.NULL_FILE
end

---@static
---@param adapter VCSAdapter
function FileEntry.update_index_stat(adapter, stat)
  stat = stat or pl:stat(pl:join(adapter.ctx.toplevel, "index"))

  if stat then
    if not fstat_cache[adapter.ctx.toplevel] then
      fstat_cache[adapter.ctx.toplevel] = {}
    end

    fstat_cache[adapter.ctx.toplevel].index = {
      mtime = stat.mtime.sec,
    }
  end
end

---@class FileEntry.with_layout.Opt : FileEntry.init.Opt
---@field nulled boolean
---@field get_data git.FileDataProducer?

---@param layout_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return FileEntry
function FileEntry.with_layout(layout_class, opt)
  local function create_file(rev, symbol)
    return File({
      adapter = opt.adapter,
      path = symbol == "a" and opt.oldpath or opt.path,
      kind = opt.kind,
      commit = opt.commit,
      get_data = opt.get_data,
      rev = rev,
      nulled = utils.sate(
        opt.nulled,
        select(2, pcall(layout_class.should_null, rev, opt.status, symbol))
      ),
    }) --[[@as vcs.File ]]
  end

  return FileEntry({
    adapter = opt.adapter,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    revs = opt.revs,
    layout = layout_class({
      a = create_file(opt.revs.a, "a"),
      b = create_file(opt.revs.b, "b"),
      c = create_file(opt.revs.c, "c"),
      d = create_file(opt.revs.d, "d"),
    }),
  })
end

function FileEntry.new_null_entry(adapter)
  return FileEntry({
    adapter = adapter,
    path = "null",
    kind = "working",
    binary = false,
    nulled = true,
    layout = Diff1({
      b = File.NULL_FILE,
    })
  })
end

M.FileEntry = FileEntry

return M
