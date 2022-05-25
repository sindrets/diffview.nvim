local Job = require("plenary.job")
local Panel = require("diffview.ui.panel").Panel
local async = require("plenary.async")
local get_user_config = require("diffview.config").get_config
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

---@class CommitLogPanel : Panel
---@field git_root string
---@field args string[]
---@field job_out string[]
local CommitLogPanel = oop.create_class("CommitLogPanel", Panel)

CommitLogPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  wrap = true,
  breakindent = true,
})

CommitLogPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  buftype = "nowrite",
  filetype = "git",
})

CommitLogPanel.default_type = "float"

CommitLogPanel.default_config_split = vim.tbl_extend("force", Panel.default_config_split, {
  position = "bottom",
  height = 14,
})

CommitLogPanel.default_config_float = function()
  local c = vim.deepcopy(Panel.default_config_float)
  local viewport_width = vim.o.columns
  local viewport_height = vim.o.lines
  c.width = math.min(100, viewport_width)
  c.height = math.min(24, viewport_height)
  c.col = math.floor(viewport_width * 0.5 - c.width * 0.5)
  c.row = math.floor(viewport_height * 0.5 - c.height * 0.5)
  return c
end

---@class CommitLogPanelSpec
---@field config PanelConfig
---@field args string[]
---@field name string

---@param git_root string
---@param opt CommitLogPanelSpec
function CommitLogPanel:init(git_root, opt)
  CommitLogPanel:super().init(self, {
    bufname = opt.name,
    config = opt.config or get_user_config().commit_log_panel.win_config,
  })
  self.git_root = git_root
  self.args = opt.args or { "-n256" }

  self:on_autocmd("BufWinEnter" , {
    callback = function()
      vim.bo[self.bufid].bufhidden = "wipe"
    end,
  })
end

---@param self CommitLogPanel
---@param args string|string[]
CommitLogPanel.update = async.void(function(self, args)
  if type(args) ~= "table" then
    args = { args }
  end

  Job:new({
    command = "git",
    args = utils.vec_join(
      "log",
      "--first-parent",
      "--stat",
      args or self.args
    ),
    cwd = self.git_root,
    on_exit = vim.schedule_wrap(function(job)
      if job.code ~= 0 then
        utils.err("Failed to open log!")
        utils.handle_job(job)
        return
      end

      self.job_out = job:result()
      if not self:is_open() then
        self:init_buffer()
      else
        self:render()
        self:redraw()
      end
      self:focus()
      vim.cmd("norm! gg")
    end),
  }):start()
end)

function CommitLogPanel:update_components()
end

function CommitLogPanel:render()
  self.render_data:clear()
  if self.job_out then
    self.render_data.lines = utils.vec_slice(self.job_out)
  end
end

M.CommitLogPanel = CommitLogPanel
return M
