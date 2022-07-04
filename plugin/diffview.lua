if vim.g.diffview_nvim_loaded or not require("diffview.bootstrap") then
  return
end

vim.g.diffview_nvim_loaded = 1

local lazy = require("diffview.lazy")

---@module "diffview"
local diffview = lazy.require("diffview")

local api = vim.api
local command = api.nvim_create_user_command

-- NOTE: Need this wrapper around the completion function becuase it doesn't
-- exist yet.
local function completion(...)
  return diffview.completion(...)
end

-- Create commands
command("DiffviewOpen", function(state)
  diffview.open(unpack(state.fargs))
end, { nargs = "*", complete = completion })

command("DiffviewFileHistory", function(state)
  local range

  if state.range > 0 then
    range = { state.line1, state.line2 }
  end

  diffview.file_history(range, unpack(state.fargs))
end, { nargs = "*", complete = completion, range = true })

command("DiffviewClose", function()
  diffview.close()
end, { nargs = 0, bang = true })

command("DiffviewFocusFiles", function()
  diffview.emit("focus_files")
end, { nargs = 0, bang = true })

command("DiffviewToggleFiles", function()
  diffview.emit("toggle_files")
end, { nargs = 0, bang = true })

command("DiffviewRefresh", function()
  diffview.emit("refresh_files")
end, { nargs = 0, bang = true })

command("DiffviewLog", function()
  vim.cmd(("sp %s | norm! G"):format(
    vim.fn.fnameescape(require("diffview.logger").outfile)
  ))
end, { nargs = 0, bang = true })
