local oop = require'diffview.oop'
local utils = require'diffview.utils'
local EventEmitter = require'diffview.events'.EventEmitter
local View = require'diffview.scene.view'.View
local CFileEntry = require'diffview.api.c_file_entry'.CFileEntry
local FilePanel = require'diffview.scene.file_panel'.FilePanel
local FileDict = require'diffview.git'.FileDict
local Rev = require'diffview.rev'.Rev
local RevType = require'diffview.rev'.RevType
local git = require'diffview.git'

local M = {}

---@class FileData
---@field path string Path relative to git root.
---@field oldpath string|nil If the file has been renamed, this should be the old path, oterhwise nil.
---@field status string Git status symbol.
---@field stats GitStats|nil
---@field left_null boolean Indicates that the left buffer should be represented by the null buffer.
---@field right_null boolean Indicates that the right buffer should be represented by the null buffer.
---@field selected boolean|nil Indicates that this should be the initially selected file.

---@class CView
---@field files any
---@field fetch_files function A function that should return an updated list of files.
---@field get_file_data function A function that is called with parameters `path: string` and `split: string`, and should return a list of lines that should make up the buffer.
local CView = View
CView = oop.create_class("CView", View)

---CView constructor.
---@param opt any
function CView:init(opt)
  self.git_root = opt.git_root
  self.git_dir = git.git_dir(opt.git_root)
  self.rev_arg = opt.rev_arg
  self.path_args = opt.path_args
  self.left = opt.left
  self.right = opt.right
  self.options = opt.options
  self.emitter = EventEmitter()
  self.layout_mode = CView.get_layout_mode()
  self.files = FileDict()
  self.file_idx = 1
  self.nulled = false
  self.ready = false
  self.fetch_files = opt.update_files
  self.get_file_data = opt.get_file_data
  self.file_panel = FilePanel(
    self.git_root,
    self.files,
    self.path_args,
    self.rev_arg or git.rev_to_pretty_string(self.left, self.right)
  )

  local files, selected = self:create_file_entries(opt.files)
  self.file_idx = selected

  for kind, entries in pairs(files) do
    for _, entry in ipairs(entries) do
      table.insert(self.files[kind], entry)
    end
  end
end

---@override
function CView:get_updated_files()
  return self:create_file_entries(self.fetch_files(self))
end

function CView:create_file_entries(files)
  local entries = {}
  local i, file_idx = 1, 1

  local sections = {
    { kind = "working", files = files.working, left = self.left, right = self.right },
    {
      kind = "staged", files = files.staged, left = git.head_rev(self.git_root),
      right = Rev(RevType.INDEX)
    }
  }

  for _, v in ipairs(sections) do
    entries[v.kind] = {}
    for _, file_data in ipairs(v.files) do
      table.insert(entries[v.kind], CFileEntry({
          path = file_data.path,
          oldpath = file_data.oldpath,
          absolute_path = utils.path_join({ self.git_root, file_data.path }),
          status = file_data.status,
          stats = file_data.stats,
          kind = v.kind,
          left = v.left,
          right = v.right,
          left_null = file_data.left_null,
          right_null = file_data.right_null,
          get_file_data = self.get_file_data
        }))

      if file_data.selected == true then
        file_idx = i
      end
      i = i + 1
    end
  end

  return entries, file_idx
end

M.CView = CView
return M
