local utils = require'diffview.utils'
local View = require'diffview.view'.View
local CFileEntry = require'diffview.api.c-file-entry'.CFileEntry
local FilePanel = require'diffview.file-panel'.FilePanel
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
---@field update_files function A function that should return an updated list of files.
---@field get_file_data function A function that is called with parameters `path: string` and `split: string`, and should return a list of lines that should make up the buffer.
---INHERITED:
---@field tabpage integer
---@field git_root string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field options ViewOptions
---@field layout_mode LayoutMode
---@field file_panel FilePanel
---@field left_winid integer
---@field right_winid integer
---@field file_idx integer
---@field nulled boolean
---@field ready boolean
---STATIC-MEMBERS:
---@field get_layout_mode function
local CView = utils.class(View)

---CView constructor.
---@param opt any
---@return CView
function CView:new(opt)
  local this = {
    git_root = opt.git_root,
    path_args = opt.path_args,
    left = opt.left,
    right = opt.right,
    options = opt.options,
    layout_mode = CView.get_layout_mode(),
    files = FileDict:new(),
    file_idx = 1,
    nulled = false,
    ready = false,
    update_files = opt.update_files,
    get_file_data = opt.get_file_data
  }

  local files = {
    {
      this_files = this.files.working, opt_files = opt.files.working or {},
      kind = "working", left = this.left, right = this.right
    },
    {
      this_files = this.files.staged, opt_files = opt.files.staged or {},
      kind = "staged", left = git.head_rev(this.git_root), right = Rev:new(RevType.INDEX)
    }
  }

  for _, v in ipairs(files) do
    ---@type FileData
    for i, file_data in ipairs(v.opt_files) do
      table.insert(v.this_files, CFileEntry:new({
          path = file_data.path,
          oldpath = file_data.oldpath,
          absolute_path = utils.path_join({ this.git_root, file_data.path }),
          status = file_data.status,
          stats = file_data.stats,
          kind = v.kind,
          left = v.left,
          right = v.right,
          left_null = file_data.left_null,
          right_null = file_data.right_null,
          get_file_data = this.get_file_data
        }))
      if file_data.selected == true then
        this.file_idx = i
      end
    end
  end

  this.file_panel = FilePanel:new(
    this.git_root,
    this.files,
    this.path_args,
    git.rev_to_pretty_string(this.left, this.right)
  )

  setmetatable(this, self)
  return this
end

---@override
function CView:get_updated_files()
  return self.update_files(self)
end

M.CView = CView
return M
