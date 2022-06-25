local CFileEntry = require("diffview.api.views.file_entry").CFileEntry
local DiffView = require("diffview.views.diff.diff_view").DiffView
local EventEmitter = require("diffview.events").EventEmitter
local FileDict = require("diffview.git.file_dict").FileDict
local FilePanel = require("diffview.views.diff.file_panel").FilePanel
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
  self.git_dir = git.git_dir(opt.git_root)

  if not self.git_dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(opt.git_root))
    )
    return
  end

  self.emitter = EventEmitter()
  self.layout_mode = CDiffView.get_layout_mode()
  self.nulled = false
  self.ready = false
  self.closing = false
  self.winopts = { left = {}, right = {} }
  self.git_root = opt.git_root
  self.rev_arg = opt.rev_arg
  self.path_args = opt.path_args
  self.left = opt.left
  self.right = opt.right
  self.options = opt.options or {}
  self.files = FileDict()
  self.fetch_files = opt.update_files
  self.get_file_data = opt.get_file_data
  self.panel = FilePanel(
    self.git_root,
    self.files,
    self.path_args,
    self.rev_arg or git.rev_to_pretty_string(self.left, self.right)
  )

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

---@Override
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
      left = git.head_rev(self.git_root),
      right = Rev(RevType.INDEX),
    },
  }

  for _, v in ipairs(sections) do
    entries[v.kind] = {}
    for _, file_data in ipairs(v.files) do
      table.insert(
        entries[v.kind],
        CFileEntry({
          path = file_data.path,
          oldpath = file_data.oldpath,
          absolute_path = utils.path:join(self.git_root, file_data.path),
          status = file_data.status,
          stats = file_data.stats,
          kind = v.kind,
          left = v.left,
          right = v.right,
          left_null = file_data.left_null,
          right_null = file_data.right_null,
          get_file_data = self.get_file_data,
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
