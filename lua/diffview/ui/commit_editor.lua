--[[
A commit message editor: the equivalent of the commit input box in VSCode's
source control panel.

Opens a scratch 'gitcommit' buffer in a split below the view. Writing the
buffer - or pressing the commit mapping - commits the staged changes.
--]]

local lazy = require("diffview.lazy")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local fmt = string.format

local M = {}

---@type integer?
local cur_bufnr

---@class diffview.CommitEditor.Opt
---@field adapter VCSAdapter
---@field amend? boolean
---@field on_done? fun(committed: boolean)

---@param adapter VCSAdapter
---@param amend boolean
---@return string[]
local function initial_content(adapter, amend)
  local lines = {}

  if amend then
    local msg = adapter:exec_sync({ "log", "-1", "--pretty=%B" }, adapter.ctx.toplevel)

    for _, line in ipairs(msg or {}) do
      lines[#lines + 1] = line
    end

    -- Drop the trailing blank lines of the previous message.
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
      lines[#lines] = nil
    end
  end

  if #lines == 0 then lines[1] = "" end

  vim.list_extend(lines, {
    "",
    "# Write the commit message above.",
    fmt("# Press '%s' or write the buffer (':w') to commit, 'q' to abort.", "<C-c><C-c>"),
    "# Lines starting with '#' are ignored, and an empty message aborts the commit.",
    "#",
  })

  if amend then
    lines[#lines + 1] = "# You are amending the previous commit."
    lines[#lines + 1] = "#"
  end

  local status = adapter:exec_sync(
    { "-c", "color.status=false", "status", "--short", "--branch" },
    adapter.ctx.toplevel
  )

  for _, line in ipairs(status or {}) do
    if line ~= "" then lines[#lines + 1] = "# " .. line end
  end

  return lines
end

---@param bufnr integer
---@return string message
local function get_message(bufnr)
  local lines = vim.tbl_filter(function(line)
    return line:sub(1, 1) ~= "#"
  end, api.nvim_buf_get_lines(bufnr, 0, -1, false))

  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end

  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end

  return table.concat(lines, "\n")
end

---@param winid integer
---@param bufnr integer
local function close(winid, bufnr)
  if cur_bufnr == bufnr then cur_bufnr = nil end

  if api.nvim_win_is_valid(winid) then
    api.nvim_win_close(winid, true)
  end

  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_delete(bufnr, { force = true })
  end
end

---Open the commit message editor.
---@param opt diffview.CommitEditor.Opt
function M.open(opt)
  local adapter = opt.adapter

  if cur_bufnr and api.nvim_buf_is_valid(cur_bufnr) then
    utils.err("A commit message editor is already open!")
    return
  end

  if not adapter:supports_committing() then
    utils.err(fmt("Committing is not supported by the '%s' adapter!", adapter.class:name()))
    return
  end

  if not opt.amend and not adapter:has_staged_changes() then
    utils.err("There are no staged changes to commit! Stage some changes first.")
    return
  end

  local bufnr = api.nvim_create_buf(false, true)
  cur_bufnr = bufnr

  api.nvim_buf_set_name(bufnr, fmt("diffview://%s/COMMIT_EDITMSG", adapter.ctx.dir))
  api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_content(adapter, opt.amend or false))

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "gitcommit"
  vim.bo[bufnr].modified = false

  -- Full width, at the very bottom: the file panel is usually a narrow split.
  vim.cmd("botright split")
  local winid = api.nvim_get_current_win()
  api.nvim_win_set_buf(winid, bufnr)
  api.nvim_win_set_height(winid, math.min(16, #api.nvim_buf_get_lines(bufnr, 0, -1, false) + 1))
  vim.wo[winid].winfixheight = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].spell = true
  utils.set_cursor(winid, 1, 0)

  local done = false

  local function finish(committed)
    if done then return end
    done = true
    close(winid, bufnr)
    if opt.on_done then opt.on_done(committed) end
  end

  local function commit()
    local msg = get_message(bufnr)

    if msg == "" then
      utils.err("Aborting commit due to an empty commit message.")
      return
    end

    local ok, out, stderr = adapter:commit(msg, { amend = opt.amend })

    if not ok then
      utils.err(utils.vec_join("Failed to commit!", stderr), true)
      return
    end

    vim.bo[bufnr].modified = false
    finish(true)

    local summary = vim.trim((out or {})[1] or "")
    utils.info(summary ~= "" and ("Commit: " .. summary) or "Changes committed.", true)
  end

  local km_opt = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-c><C-c>", function()
    vim.cmd("stopinsert")
    commit()
  end, km_opt)
  vim.keymap.set("n", "q", function() finish(false) end, km_opt)

  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function() commit() end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if cur_bufnr == bufnr then cur_bufnr = nil end
      if not done then
        done = true
        if opt.on_done then opt.on_done(false) end
      end
    end,
  })

  vim.cmd("startinsert")
end

return M
