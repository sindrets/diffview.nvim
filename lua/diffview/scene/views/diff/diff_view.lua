local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local CommitLogPanel = lazy.access("diffview.ui.panels.commit_log_panel", "CommitLogPanel") ---@type CommitLogPanel|LazyModule
local Diff = lazy.access("diffview.diff", "Diff") ---@type Diff|LazyModule
local EditToken = lazy.access("diffview.diff", "EditToken") ---@type EditToken|LazyModule
local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local FileDict = lazy.access("diffview.vcs.file_dict", "FileDict") ---@type FileDict|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local FilePanel = lazy.access("diffview.scene.views.diff.file_panel", "FilePanel") ---@type FilePanel|LazyModule
local PerfTimer = lazy.access("diffview.perf", "PerfTimer") ---@type PerfTimer|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"
local GitAdapter = lazy.access("diffview.vcs.adapters.git", "GitAdapter") ---@type GitAdapter|LazyModule

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

---@class DiffViewOptions
---@field show_untracked? boolean
---@field selected_file? string Path to the preferred initially selected file.

---@class DiffView : StandardView
---@operator call : DiffView
---@field adapter VCSAdapter
---@field rev_arg string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field options DiffViewOptions
---@field panel FilePanel
---@field commit_log_panel CommitLogPanel
---@field files FileDict
---@field file_idx integer
---@field merge_ctx? vcs.MergeContext
---@field initialized boolean
---@field valid boolean
---@field watcher uv_fs_poll_t # UV fs poll handle.
local DiffView = oop.create_class("DiffView", StandardView.__get())

---DiffView constructor
function DiffView:init(opt)
  self.valid = false
  self.files = FileDict()
  self.adapter = opt.adapter
  self.path_args = opt.path_args
  self.rev_arg = opt.rev_arg
  self.left = opt.left
  self.right = opt.right
  self.initialized = false
  self.options = opt.options or {}
  self.options.selected_file = self.options.selected_file
    and pl:chain(self.options.selected_file)
        :absolute()
        :relative(self.adapter.ctx.toplevel)
        :get()

  self:super({
    panel = FilePanel(
      self.adapter,
      self.files,
      self.path_args,
      self.rev_arg or self.adapter:rev_to_pretty_string(self.left, self.right)
    ),
  })

  self.attached_bufs = {}
  self.emitter:on("file_open_post", utils.bind(self.file_open_post, self))
  self.valid = true
end

function DiffView:post_open()
  vim.cmd("redraw")

  self.commit_log_panel = CommitLogPanel(self.adapter, {
    name = fmt("diffview://%s/log/%d/%s", self.adapter.ctx.dir, self.tabpage, "commit_log"),
  })

  if config.get_config().watch_index and self.adapter:instanceof(GitAdapter.__get()) then
    self.watcher = vim.loop.new_fs_poll()
    self.watcher:start(
      self.adapter.ctx.dir .. "/index",
      1000,
      ---@diagnostic disable-next-line: unused-local
      vim.schedule_wrap(function(err, prev, cur)
        if not err then
          if self:is_cur_tabpage() then
            self:update_files()
          end
        end
      end)
    )
  end

  self:init_event_listeners()

  vim.schedule(function()
    self:file_safeguard()
    if self.files:len() == 0 then
      self:update_files()
    end
    self.ready = true
  end)
end

---@param e Event
---@param new_entry FileEntry
---@param old_entry FileEntry
---@diagnostic disable-next-line: unused-local
function DiffView:file_open_post(e, new_entry, old_entry)
  if new_entry.layout:is_nulled() then return end
  if new_entry.kind == "conflicting" then
    local file = new_entry.layout:get_main_win().file

    local count_conflicts = vim.schedule_wrap(function()
      local conflicts = vcs_utils.parse_conflicts(api.nvim_buf_get_lines(file.bufnr, 0, -1, false))

      new_entry.stats = new_entry.stats or {}
      new_entry.stats.conflicts = #conflicts

      self.panel:render()
      self.panel:redraw()
    end)

    count_conflicts()

    if file.bufnr and not self.attached_bufs[file.bufnr] then
      self.attached_bufs[file.bufnr] = true

      local work = debounce.throttle_trailing(
        1000,
        true,
        vim.schedule_wrap(function()
          if not self:is_cur_tabpage() or self.cur_entry ~= new_entry then
            self.attached_bufs[file.bufnr] = false
            return
          end

          count_conflicts()
        end)
      )

      api.nvim_create_autocmd(
        { "TextChanged", "TextChangedI" },
        {
          buffer = file.bufnr,
          callback = function()
            if not self.attached_bufs[file.bufnr] then
              work:close()
              return true
            end

            work()
          end,
        }
      )
    end
  end
end

---@override
function DiffView:close()
  if not self.closing:check() then
    self.closing:send()

    if self.watcher then
      self.watcher:stop()
      self.watcher:close()
    end

    for _, file in self.files:iter() do
      file:destroy()
    end

    self.commit_log_panel:destroy()
    DiffView.super_class.close(self)
  end
end

---@private
---@param self DiffView
---@param file FileEntry
DiffView._set_file = async.void(function(self, file)
  self.panel:render()
  self.panel:redraw()
  vim.cmd("redraw")

  self.cur_layout:detach_files()
  local cur_entry = self.cur_entry
  self.emitter:emit("file_open_pre", file, cur_entry)
  self.nulled = false

  await(self:use_entry(file))

  self.emitter:emit("file_open_post", file, cur_entry)

  if not self.cur_entry.opened then
    self.cur_entry.opened = true
    DiffviewGlobal.emitter:emit("file_open_new", file)
  end
end)

---Open the next file.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
---@return FileEntry?
function DiffView:next_file(highlight)
  self:ensure_layout()

  if self:file_safeguard() then return end

  if self.files:len() > 1 or self.nulled then
    local cur = self.panel:next_file()

    if cur then
      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(cur)
      end

      self:_set_file(cur)

      return cur
    end
  end
end

---Open the previous file.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
---@return FileEntry?
function DiffView:prev_file(highlight)
  self:ensure_layout()

  if self:file_safeguard() then return end

  if self.files:len() > 1 or self.nulled then
    local cur = self.panel:prev_file()

    if cur then
      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(cur)
      end

      self:_set_file(cur)

      return cur
    end
  end
end

---Set the active file.
---@param self DiffView
---@param file FileEntry
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
DiffView.set_file = async.void(function(self, file, focus, highlight)
  ---@diagnostic disable: invisible
  self:ensure_layout()

  if self:file_safeguard() or not file then return end

  for _, f in self.files:iter() do
    if f == file then
      self.panel:set_cur_file(file)

      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(file)
      end

      await(self:_set_file(file))

      if focus then
        api.nvim_set_current_win(self.cur_layout:get_main_win().id)
      end
    end
  end
  ---@diagnostic enable: invisible
end)

---Set the active file.
---@param self DiffView
---@param path string
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
DiffView.set_file_by_path = async.void(function(self, path, focus, highlight)
  ---@type FileEntry
  for _, file in self.files:iter() do
    if file.path == path then
      await(self:set_file(file, focus, highlight))
      return
    end
  end
end)

---Get an updated list of files.
---@param self DiffView
---@param callback fun(err?: string[], files: FileDict)
DiffView.get_updated_files = async.wrap(function(self, callback)
  vcs_utils.diff_file_list(
    self.adapter,
    self.left,
    self.right,
    self.path_args,
    self.options,
    {
      default_layout = DiffView.get_default_layout(),
      merge_layout = DiffView.get_default_merge_layout(),
    },
    callback
  )
end)

---Update the file list, including stats and status for all files.
DiffView.update_files = debounce.debounce_trailing(
  100,
  true,
  ---@param self DiffView
  ---@param callback fun(err?: string[])
  async.wrap(function(self, callback)
    await(async.scheduler())

    -- Never update unless the view is in focus
    if self.tabpage ~= api.nvim_get_current_tabpage() then
      callback({ "The update was cancelled." })
      return
    end

    ---@type PerfTimer
    local perf = PerfTimer("[DiffView] Status Update")
    self:ensure_layout()

    -- If left is tracking HEAD and right is LOCAL: Update HEAD rev.
    local new_head
    if self.left.track_head and self.right.type == RevType.LOCAL then
      new_head = self.adapter:head_rev()
      if new_head and self.left.commit ~= new_head.commit then
        self.left = new_head
      else
        new_head = nil
      end
      perf:lap("updated head rev")
    end

    local index_stat = pl:stat(pl:join(self.adapter.ctx.dir, "index"))

    ---@type string[]?, FileDict
    local err, new_files = await(self:get_updated_files())
    await(async.scheduler())

    if err then
      utils.err("Failed to update files in a diff view!", true)
      logger:error("[DiffView] Failed to update files!")
      callback(err)
      return
    end

    -- Stop the update if the view is no longer in focus.
    if self.tabpage ~= api.nvim_get_current_tabpage() then
      callback({ "The update was cancelled." })
      return
    end

    perf:lap("received new file list")

    local files = {
      { cur_files = self.files.conflicting, new_files = new_files.conflicting },
      { cur_files = self.files.working, new_files = new_files.working },
      { cur_files = self.files.staged, new_files = new_files.staged },
    }

    for _, v in ipairs(files) do
      -- We diff the old file list against the new file list in order to find
      -- the most efficient way to morph the current list into the new. This
      -- way we avoid having to discard and recreate buffers for files that
      -- exist in both lists.
      ---@param aa FileEntry
      ---@param bb FileEntry
      local diff = Diff(v.cur_files, v.new_files, function(aa, bb)
        return aa.path == bb.path and aa.oldpath == bb.oldpath
      end)

      local script = diff:create_edit_script()
      local ai = 1
      local bi = 1

      for _, opr in ipairs(script) do
        if opr == EditToken.NOOP then
          -- Update status and stats
          local a_stats = v.cur_files[ai].stats
          local b_stats = v.new_files[bi].stats

          if a_stats then
            v.cur_files[ai].stats = vim.tbl_extend("force", a_stats, b_stats or {})
          else
            v.cur_files[ai].stats = v.new_files[bi].stats
          end

          v.cur_files[ai].status = v.new_files[bi].status
          v.cur_files[ai]:validate_stage_buffers(index_stat)

          if new_head then
            v.cur_files[ai]:update_heads(new_head)
          end

          ai = ai + 1
          bi = bi + 1

        elseif opr == EditToken.DELETE then
          if self.panel.cur_file == v.cur_files[ai] then
            local file_list = self.panel:ordered_file_list()
            if file_list[1] == self.panel.cur_file then
              self.panel:set_cur_file(nil)
            else
              self.panel:set_cur_file(self.panel:prev_file())
            end
          end

          v.cur_files[ai]:destroy()
          table.remove(v.cur_files, ai)

        elseif opr == EditToken.INSERT then
          table.insert(v.cur_files, ai, v.new_files[bi])
          ai = ai + 1
          bi = bi + 1

        elseif opr == EditToken.REPLACE then
          if self.panel.cur_file == v.cur_files[ai] then
            local file_list = self.panel:ordered_file_list()
            if file_list[1] == self.panel.cur_file then
              self.panel:set_cur_file(nil)
            else
              self.panel:set_cur_file(self.panel:prev_file())
            end
          end

          v.cur_files[ai]:destroy()
          v.cur_files[ai] = v.new_files[bi]
          ai = ai + 1
          bi = bi + 1
        end
      end
    end

    perf:lap("updated file list")

    self.merge_ctx = next(new_files.conflicting) and self.adapter:get_merge_context() or nil

    if self.merge_ctx then
      for _, entry in ipairs(self.files.conflicting) do
        entry:update_merge_context(self.merge_ctx)
      end
    end

    FileEntry.update_index_stat(self.adapter, index_stat)
    self.files:update_file_trees()
    self.panel:update_components()
    self.panel:render()
    self.panel:redraw()
    perf:lap("panel redrawn")
    self.panel:reconstrain_cursor()

    if utils.vec_indexof(self.panel:ordered_file_list(), self.panel.cur_file) == -1 then
      self.panel:set_cur_file(nil)
    end

    -- Set initially selected file
    if not self.initialized and self.options.selected_file then
      for _, file in self.files:iter() do
        if file.path == self.options.selected_file then
          self.panel:set_cur_file(file)
          break
        end
      end
    end
    self:set_file(self.panel.cur_file or self.panel:next_file(), false, not self.initialized)

    self.update_needed = false
    perf:time()
    logger:lvl(5):debug(perf)
    logger:fmt_info(
      "[%s] Completed update for %d files successfully (%.3f ms)",
      self.class:name(),
      self.files:len(),
      perf.final_time
    )
    self.emitter:emit("files_updated", self.files)

    callback()
  end)
)

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function DiffView:file_safeguard()
  if self.files:len() == 0 then
    local cur = self.panel.cur_file

    if cur then
      cur.layout:detach_files()
    end

    self.cur_layout:open_null()
    self.nulled = true

    return true
  end
  return false
end

function DiffView:on_files_staged(callback)
  self.emitter:on(EventName.FILES_STAGED, callback)
end

function DiffView:init_event_listeners()
  local listeners = require("diffview.scene.views.diff.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

---Infer the current selected file. If the file panel is focused: return the
---file entry under the cursor. Otherwise return the file open in the view.
---Returns nil if no file is open in the view, or there is no entry under the
---cursor in the file panel.
---@param allow_dir? boolean Allow directory nodes from the file tree.
---@return (FileEntry|DirData)?
function DiffView:infer_cur_file(allow_dir)
  if self.panel:is_focused() then
    ---@type any
    local item = self.panel:get_item_at_cursor()
    if not item then return end
    if not allow_dir and type(item.collapsed) == "boolean" then return end

    return item
  else
    return self.panel.cur_file
  end
end

---Check whether or not the instantiation was successful.
---@return boolean
function DiffView:is_valid()
  return self.valid
end

---Helper function to navigate commit history
---@param direction "next"|"prev" # Direction to navigate in commit history
---@return string|nil # Commit hash or nil if none available
DiffView._get_commit_in_direction = async.wrap(function(self, direction, callback)
  if not self._commit_history then
    -- Prevent race conditions by checking if we're already building
    if self._building_commit_history then
      callback(nil)
      return
    end

    self._building_commit_history = true
    local err = await(self:_build_commit_history())
    self._building_commit_history = false

    if err then
      callback(nil)
      return
    end
  end

  local current_commit = self:_get_current_commit_hash()
  if not current_commit then
    callback(nil)
    return
  end

  local current_idx = nil
  for i, commit_hash in ipairs(self._commit_history) do
    if commit_hash == current_commit then
      current_idx = i
      break
    end
  end

  if not current_idx then
    callback(nil)
    return
  end

  if direction == "next" then
    if current_idx >= #self._commit_history then
      callback(nil)
    else
      callback(self._commit_history[current_idx + 1])
    end
  elseif direction == "prev" then
    if current_idx <= 1 then
      callback(nil)
    else
      callback(self._commit_history[current_idx - 1])
    end
  else
    callback(nil)
  end
end)

---Get the next commit in the commit history
---@return string|nil # Next commit hash or nil if none available
DiffView.get_older_commit = async.wrap(function(self, callback)
  local result = await(self:_get_commit_in_direction("next"))
  callback(result)
end)

---Get the previous commit in the commit history
---@return string|nil # Previous commit hash or nil if none available
DiffView.get_newer_commit = async.wrap(function(self, callback)
  local result = await(self:_get_commit_in_direction("prev"))
  callback(result)
end)

---Build commit history for navigation
---@private
---@return string|nil # Error message if failed
DiffView._build_commit_history = async.wrap(function(self, callback)
  local Job = require("diffview.job").Job

  -- Build git log arguments based on the diff view context
  local args = { "log", "--pretty=format:%H", "--no-merges", "--first-parent" }

  -- Always use HEAD to get the full commit history for navigation
  -- We need the complete history to navigate forward/backward through commits
  table.insert(args, "HEAD")

  -- Add path arguments if any
  if self.path_args and #self.path_args > 0 then
    table.insert(args, "--")
    for _, path in ipairs(self.path_args) do
      table.insert(args, path)
    end
  end

  local job = Job({
    command = "git",
    args = args,
    cwd = self.adapter.ctx.toplevel,
  })

  local ok = await(job)
  if not ok then
    callback("Failed to get commit history: " .. table.concat(job.stderr or {}, "\n"))
    return
  end

  local raw_output = table.concat(job.stdout or {}, "\n")
  self._commit_history = vim.split(raw_output, "\n", { trimempty = true })
  callback(nil)
end)

---Get current commit hash being viewed
---@private
---@return string|nil
function DiffView:_get_current_commit_hash()
  if self.right.commit then
    -- Handle both cases: commit object with .hash property, or commit being the hash itself
    return type(self.right.commit) == "table" and self.right.commit.hash or self.right.commit
  elseif self.left.commit then
    -- Handle both cases: commit object with .hash property, or commit being the hash itself
    return type(self.left.commit) == "table" and self.left.commit.hash or self.left.commit
  end
  return nil
end

---Set the current commit being viewed
---@param commit_hash string
DiffView.set_commit = async.void(function(self, commit_hash)
  local RevType = require("diffview.vcs.rev").RevType
  local Job = require("diffview.job").Job

  -- Resolve the parent commit hash using git rev-parse
  local parent_job = Job({
    command = "git",
    args = { "rev-parse", commit_hash .. "^" },
    cwd = self.adapter.ctx.toplevel,
  })

  local ok = await(parent_job)
  local new_left, new_right

  if not ok or not parent_job.stdout or #parent_job.stdout == 0 then
    -- Fallback: use the string reference if we can't resolve it
    new_left = self.adapter.Rev(RevType.COMMIT, commit_hash .. "~1")
    new_right = self.adapter.Rev(RevType.COMMIT, commit_hash)
  else
    -- Use the resolved parent commit hash
    local parent_hash = vim.trim(parent_job.stdout[1])
    new_left = self.adapter.Rev(RevType.COMMIT, parent_hash)
    new_right = self.adapter.Rev(RevType.COMMIT, commit_hash)
  end

  -- Update the view's revisions
  self.left = new_left
  self.right = new_right

  -- Update the panel's pretty name to reflect the new commit
  -- For single commits, show the conventional git format: commit_hash^..commit_hash
  local right_abbrev = new_right:abbrev()
  self.panel.rev_pretty_name = right_abbrev .. "^.." .. right_abbrev

  -- Update files and refresh the view
  self:update_files()

  -- Update panel to show current commit info and refresh diff content
  vim.schedule(function()
    self.panel:render()
    self.panel:redraw()

    -- If there's a currently selected file, update its revisions and refresh
    -- This needs to be scheduled to avoid fast event context issues
    if self.cur_entry then
      -- Update the current entry's file revisions to match the new commit
      if self.cur_entry.layout and self.cur_entry.layout.a and self.cur_entry.layout.b then
        -- Dispose old buffers to prevent cached stale content
        self.cur_entry.layout.a.file:dispose_buffer()
        self.cur_entry.layout.b.file:dispose_buffer()

        -- Update the file objects with new revisions
        self.cur_entry.layout.a.file.rev = new_left
        self.cur_entry.layout.b.file.rev = new_right

        -- Force refresh by calling use_entry again
        self:use_entry(self.cur_entry)
      end
    end
  end)
end)

M.DiffView = DiffView

return M
