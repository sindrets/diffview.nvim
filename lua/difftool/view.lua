local a = vim.api
local M = {}

---@class View
---@field tabpage integer
---@field git_root string
---@field paths string[]
---@field left Rev
---@field right Rev
local View = {}
View.__index = View

---View constructor
---@return View
function View:new(opt)
  local this = {
    git_root = opt.git_root,
    paths = opt.paths,
    left = opt.left,
    right = opt.right
  }
  setmetatable(this, self)
  return this
end

function View:open()
  vim.cmd("tabnew")
  self.tabpage = a.nvim_get_current_tabpage()
end

function View:close()
  if self.tabpage then
    vim.cmd("tabclose " .. self.tabpage)
  end
end

M.View = View

return M
