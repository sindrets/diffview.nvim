local FileEntry = require("diffview.scene.file_entry").FileEntry
local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
local Rev = require("diffview.git.rev").Rev
local RevType = require("diffview.git.rev").RevType
local async = require("plenary.async")
local git = require("diffview.git.utils")
local logger = require("diffview.logger")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

---@class FileData
---@field path string Path relative to git root.
---@field oldpath string|nil If the file has been renamed, this should be the old path, oterhwise nil.
---@field status string Git status symbol.
---@field stats GitStats|nil
---@field left_null boolean Indicates that the left buffer should be represented by the null buffer.
---@field right_null boolean Indicates that the right buffer should be represented by the null buffer.
---@field selected boolean|nil Indicates that this should be the initially selected file.

---@class CDiffView : DiffView
---@field files any
---@field fetch_files function A function that should return an updated list of files.
---@field get_file_data function A function that is called with parameters `path: string` and `split: string`, and should return a list of lines that should make up the buffer.
local CDiffView = oop.create_class("CDiffView", DiffView)

---CDiffView constructor.
---@param opt any
function CDiffView:init(opt)
  self.valid = false
  local git_dir = git.git_dir(opt.git_root)

  if not git_dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(opt.git_root))
    )
    return
  end

  -- Fix malformed revs
  for _, v in ipairs({ "left", "right" }) do
    local rev = opt[v]
    if not rev or not rev.type then
      opt[v] = Rev(RevType.STAGE, 0)
    end
  end

  self.fetch_files = opt.update_files
  self.get_file_data = opt.get_file_data

  local git_ctx = {
    toplevel = opt.git_root,
    dir = git_dir,
  }

  CDiffView:super().init(self, vim.tbl_extend("force", opt, {
    git_ctx = git_ctx,
    panel = FilePanel(
      git_ctx,
      self.files,
      self.path_args,
      self.rev_arg or git.rev_to_pretty_string(opt.left, opt.right)
    ),
  }))

  if type(opt.files) == "table" and not vim.tbl_isempty(opt.files) then
    local files = self:create_file_entries(opt.files)

    for kind, entries in pairs(files) do
      for _, entry in ipairs(entries) do
        table.insert(self.files[kind], entry)
      end
    end
    self.files:update_file_trees()

    if self.panel.cur_file then
      vim.schedule(function()
        self:set_file(self.panel.cur_file, false, true)
      end)
    end
  end

  self.valid = true
end

---@override
CDiffView.get_updated_files = async.wrap(function(self, callback)
  local err
  callback = async.void(callback)

  repeat
    local ok, new_files = pcall(self.fetch_files, self)

    if not ok or type(new_files) ~= "table" then
      err = { "Integrating plugin failed to provide file data!" }
      break
    end

    ---@diagnostic disable-next-line: redefined-local
    local ok, entries = pcall(self.create_file_entries, self, new_files)

    if not ok then
      err = { "Integrating plugin provided malformed file data!" }
      break
    end

    callback(nil, entries)
    return
  until true

  utils.err(err, true)
  logger.s_error(table.concat(err, "\n"))
  callback(err, nil)
end, 2)

function CDiffView:create_file_entries(files)
  local entries = {}

  local sections = {
    { kind = "working", files = files.working, left = self.left, right = self.right },
    {
      kind = "staged",
      files = files.staged,
      left = git.head_rev(self.git_ctx.toplevel),
      right = Rev(RevType.STAGE, 0),
    },
  }

  for _, v in ipairs(sections) do
    entries[v.kind] = {}
    for _, file_data in ipairs(v.files) do

      table.insert(
        entries[v.kind],
        FileEntry.for_d2(CDiffView.get_default_diff2(), {
          git_ctx = self.git_ctx,
          path = file_data.path,
          oldpath = file_data.oldpath,
          status = file_data.status,
          stats = file_data.stats,
          kind = v.kind,
          rev_a = v.left,
          rev_b = v.right,
          get_data = self.get_file_data,
          --FIXME: left_null, right_null
        })
      )

      if file_data.selected then
        self.panel:set_cur_file(entries[v.kind][#entries[v.kind]])
      end
    end
  end

  return entries
end

M.CDiffView = CDiffView
return M
