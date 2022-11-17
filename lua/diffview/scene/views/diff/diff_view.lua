local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local CommitLogPanel = lazy.access("diffview.ui.panels.commit_log_panel", "CommitLogPanel") ---@type CommitLogPanel|LazyModule
local Diff = lazy.access("diffview.diff", "Diff") ---@type Diff|LazyModule
local EditToken = lazy.access("diffview.diff", "EditToken") ---@type EditToken|LazyModule
local Event = lazy.access("diffview.events", "Event") ---@type Event|LazyModule
local FileDict = lazy.access("diffview.vcs.file_dict", "FileDict") ---@type FileDict|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local FilePanel = lazy.access("diffview.scene.views.diff.file_panel", "FilePanel") ---@type FilePanel|LazyModule
local PerfTimer = lazy.access("diffview.perf", "PerfTimer") ---@type PerfTimer|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local async = lazy.require("plenary.async") ---@module "plenary.async"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local logger = lazy.require("diffview.logger") ---@module "diffview.logger"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api
local M = {}

---@class DiffViewOptions
---@field show_untracked? boolean
---@field selected_file? string Path to the preferred initially selected file.

---@class DiffView : StandardView
---@operator call:DiffView
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
---@field initialized boolean
---@field valid boolean
---@field watcher any UV fs poll handle.
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
    and utils.path:chain(self.options.selected_file)
        :absolute()
        :relative(self.adapter.ctx.toplevel)
        :get()

  DiffView:super().init(self, {
    panel = FilePanel(
      self.adapter,
      self.files,
      self.path_args,
      self.rev_arg or self.adapter:rev_to_pretty_string(self.left, self.right)
    ),
  })

  self.attached_bufs = {}

  ---@param entry FileEntry
  self.emitter:on("file_open_post", function(entry)
    if entry.kind == "conflicting" then
      local file = entry.layout:get_main_win().file

      local count_conflicts = vim.schedule_wrap(function()
        local conflicts = vcs.parse_conflicts(api.nvim_buf_get_lines(file.bufnr, 0, -1, false))

        entry.stats = entry.stats or {}
        entry.stats.conflicts = #conflicts

        self.panel:render()
        self.panel:redraw()
      end)

      count_conflicts()

      if file.bufnr and not self.attached_bufs[file.bufnr] then
        self.attached_bufs[file.bufnr] = true

        local work = debounce.throttle_trailing(1000, true, vim.schedule_wrap(function()
          if not self:is_cur_tabpage() or self.cur_entry ~= entry then
            self.attached_bufs[file.bufnr] = false
            return
          else
            count_conflicts()
          end
        end))

        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
          buffer = file.bufnr,
          callback = function()
            if not self.attached_bufs[file.bufnr] then
              work:close()
              return true
            else
              work()
            end
          end,
        })
      end
    end
  end)

  self.valid = true
end

function DiffView:post_open()
  vim.cmd("redraw")

  self.commit_log_panel = CommitLogPanel(self.adapter.ctx.toplevel, {
    name = ("diffview://%s/log/%d/%s"):format(self.adapter.ctx.dir, self.tabpage, "commit_log"),
  })

  if config.get_config().watch_index then
    self.watcher = vim.loop.new_fs_poll()
    ---@diagnostic disable-next-line: unused-local
    self.watcher:start(self.adapter.ctx.dir .. "/index", 1000, function(err, prev, cur)
      if not err then
        vim.schedule(function()
          if self:is_cur_tabpage() then
            self:update_files()
          end
        end)
      end
    end)
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

---@override
function DiffView:close()
  if not self.closing then
    self.closing = true

    if self.watcher then
      self.watcher:stop()
      self.watcher:close()
    end

    for _, file in self.files:ipairs() do
      file:destroy()
    end

    self.commit_log_panel:destroy()
    DiffView:super().close(self)
  end
end

---@private
---@param file FileEntry
function DiffView:_set_file(file)
  vim.cmd("redraw")

  self.cur_layout:detach_files()
  local cur_entry = self.cur_entry
  self.emitter:emit("file_open_pre", file, cur_entry)
  self.nulled = false

  file.layout.emitter:once("files_opened", function()
    self.emitter:emit("file_open_post", file, cur_entry)
  end)

  self:use_entry(file)
end

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
---@param file FileEntry
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
function DiffView:set_file(file, focus, highlight)
  self:ensure_layout()

  if self:file_safeguard() or not file then return end

  for _, f in self.files:ipairs() do
    if f == file then
      self.panel:set_cur_file(file)

      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(file)
      end

      self:_set_file(file)

      if focus then
        api.nvim_set_current_win(self.cur_layout:get_main_win().id)
      end
    end
  end
end

---Set the active file.
---@param path string
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
function DiffView:set_file_by_path(path, focus, highlight)
  ---@type FileEntry
  for _, file in self.files:ipairs() do
    if file.path == path then
      self:set_file(file, focus, highlight)
      return
    end
  end
end

---Get an updated list of files.
---@param self DiffView
---@param callback function
---@return string[] err
---@return FileDict
DiffView.get_updated_files = async.wrap(function(self, callback)
  vcs.diff_file_list(
      self.adapter,
      self.left,
      self.right,
      self.path_args,
      self.options,
      {
        default_layout = DiffView.get_default_diff2(),
        merge_layout = DiffView.get_default_merge_layout(),
      },
      callback
      ---@diagnostic disable-next-line: missing-return
  )
end, 2)

---Update the file list, including stats and status for all files.
DiffView.update_files = debounce.debounce_trailing(100, true, vim.schedule_wrap(
  ---@param self DiffView
  ---@param callback fun(err?: string[])
  async.void(function(self, callback)
    ---@type PerfTimer
    local perf = PerfTimer("[DiffView] Status Update")
    self:ensure_layout()

    -- If left is tracking HEAD and right is LOCAL: Update HEAD rev.
    local new_head
    if self.left.track_head and self.right.type == RevType.LOCAL then
      new_head = vcs.head_rev(self.adapter.ctx.toplevel)
      if new_head and self.left.commit ~= new_head.commit then
        self.left = new_head
      else
        new_head = nil
      end
      perf:lap("updated head rev")
    end

    local index_stat = utils.path:stat(utils.path:join(self.adapter.ctx.dir, "index"))
    local last_winid = api.nvim_get_current_win()
    self:get_updated_files(function(err, new_files)
      if err then
        utils.err("Failed to update files in a diff view!", true)
        logger.s_error("[DiffView] Failed to update files!")
        if type(callback) == "function" then
          callback(err)
        end
        return
      else
        perf:lap("received new file list")
        local files = {
          { cur_files = self.files.conflicting, new_files = new_files.conflicting },
          { cur_files = self.files.working, new_files = new_files.working },
          { cur_files = self.files.staged, new_files = new_files.staged },
        }

        async.util.scheduler()

        for _, v in ipairs(files) do
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
              v.cur_files[ai]:validate_stage_buffers(self.adapter, index_stat)

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
              table.remove(v.cur_files, ai)
              table.insert(v.cur_files, ai, v.new_files[bi])
              ai = ai + 1
              bi = bi + 1
            end
          end
        end

        perf:lap("updated file list")
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
          for _, file in self.files:ipairs() do
            if file.path == self.options.selected_file then
              self.panel:set_cur_file(file)
              break
            end
          end
        end
        self:set_file(self.panel.cur_file or self.panel:next_file(), false, not self.initialized)

        if api.nvim_win_is_valid(last_winid) then
          api.nvim_set_current_win(last_winid)
        end

        self.update_needed = false
        perf:time()
        logger.lvl(5).s_debug(perf)
        logger.s_info(
          ("[%s] Completed update for %d files successfully (%.3f ms)")
          :format(self:class():name(), self.files:len(), perf.final_time)
        )
        self.emitter:emit("files_updated", self.files)
        if type(callback) == "function" then
          callback()
        end
      end
    end)
  end)
) --[[@as function ]])

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
  self.emitter:on(Event.FILES_STAGED, callback)
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
---@return FileEntry|DirData|nil
function DiffView:infer_cur_file(allow_dir)
  if self.panel:is_focused() then
    ---@type any
    local item = self.panel:get_item_at_cursor()
    if item and (
        (item.class and item:instanceof(FileEntry.__get()))
        or (allow_dir and type(item.collapsed) == "boolean")) then
      return item
    end
  else
    return self.panel.cur_file
  end
end

---Check whether or not the instantiation was successful.
---@return boolean
function DiffView:is_valid()
  return self.valid
end

M.DiffView = DiffView

return M
