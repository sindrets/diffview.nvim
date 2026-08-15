--[[
A UI test harness.

Runs a real Neovim in a terminal buffer, with this plugin on the runtimepath
and a fixture repo as its working directory. Keys are sent to it the same way a
user would type them, and the assertions are made against what is actually
rendered on its screen - and against the state of the repo on disk.

Meant to be driven from a headless Neovim: `nvim -l scripts/ui_test.lua`.
--]]

local api = vim.api
local fmt = string.format

local M = {}

---@class diffview.UiSession
---@field bufnr integer
---@field chan integer
---@field repo string # The fixture repo.
---@field tmp string # The directory holding the fixture.
local Session = {}
Session.__index = Session

---Root of this plugin.
---@return string
local function plugin_root()
  local f = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(f, ":p:h:h:h:h")
end

---@param dir string
---@param ... string
---@return string[] stdout
---@return integer code
function M.git(dir, ...)
  local out = vim.fn.systemlist(vim.list_extend({ "git", "-C", dir }, { ... }))
  return out, vim.v.shell_error
end

---Create a repo to run the tests against: a commit with three files, and a
---handful of working tree changes on top of it.
---@return string tmp
---@return string repo
function M.make_fixture()
  local tmp = vim.fn.tempname()
  local repo = tmp .. "/repo"
  vim.fn.mkdir(repo .. "/src", "p")

  M.git(repo, "init", "-q", "-b", "main")
  M.git(repo, "config", "user.email", "test@diffview.nvim")
  M.git(repo, "config", "user.name", "Diffview Test")
  M.git(repo, "config", "commit.gpgsign", "false")

  local numbers = {}
  for i = 1, 20 do
    numbers[i] = "line " .. i
  end

  vim.fn.writefile(numbers, repo .. "/numbers.txt")
  vim.fn.writefile({ "local M = {}", "", "function M.hello()", '  return "hello"', "end", "", "return M" },
    repo .. "/src/init.lua")
  vim.fn.writefile({ "# Fixture", "", "A repo for the UI tests." }, repo .. "/README.md")

  M.git(repo, "add", "-A")
  M.git(repo, "commit", "-qm", "Initial commit")

  -- A second commit, so that there's a history to diff against.
  vim.fn.writefile({ "# Changelog", "", "- Nothing yet." }, repo .. "/CHANGELOG.md")
  M.git(repo, "add", "-A")
  M.git(repo, "commit", "-qm", "Add a changelog")

  -- Working tree changes: two separate hunks in numbers.txt, one change in
  -- src/init.lua, and an untracked file.
  numbers[2] = "line 2 CHANGED"
  numbers[18] = "line 18 CHANGED"
  vim.fn.writefile(numbers, repo .. "/numbers.txt")

  vim.fn.writefile({ "local M = {}", "", "function M.hello()", '  return "HELLO WORLD"', "end", "", "return M" },
    repo .. "/src/init.lua")

  vim.fn.writefile({ "# Fixture", "", "A repo for the UI tests.", "", "With a new paragraph." },
    repo .. "/README.md")

  vim.fn.writefile({ "brand new" }, repo .. "/untracked.txt")

  return tmp, repo
end

---Start a Neovim in a terminal buffer.
---@param opt? { repo?: string, tmp?: string, cols?: integer, rows?: integer }
---@return diffview.UiSession
function M.start(opt)
  opt = opt or {}

  local tmp, repo = opt.tmp, opt.repo

  if not repo then
    tmp, repo = M.make_fixture()
  end

  -- Give the child a screen that fits a file panel and two diff windows.
  vim.o.columns = opt.cols or 200
  vim.o.lines = opt.rows or 50
  vim.o.laststatus = 0
  vim.o.cmdheight = 1

  local init = tmp .. "/init.lua"
  vim.fn.writefile({
    fmt("vim.opt.runtimepath:append(%q)", plugin_root()),
    "vim.g.mapleader = [[\\]]",
    "vim.opt.swapfile = false",
    "vim.opt.shadafile = 'NONE'",
    "vim.opt.termguicolors = false",
    "vim.opt.laststatus = 0",
    "vim.opt.showtabline = 0",
    "vim.opt.report = 9999",
    "require('diffview').setup({ use_icons = false, show_help_hints = false })",
  }, init)

  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, bufnr)

  local cmd = { "nvim", "--clean", "-n", "-i", "NONE", "-u", init }
  local job_opt = {
    cwd = repo,
    env = {
      NVIM_APPNAME = "diffview-ui-test",
      GIT_CONFIG_GLOBAL = "/dev/null",
      GIT_CONFIG_SYSTEM = "/dev/null",
      TERM = "xterm-256color",
    },
  }

  local chan

  if vim.fn.has("nvim-0.11") == 1 then
    chan = vim.fn.jobstart(cmd, vim.tbl_extend("force", job_opt, { term = true }))
  else
    ---@diagnostic disable-next-line: deprecated
    chan = vim.fn.termopen(cmd, job_opt)
  end

  assert(chan > 0, "Failed to start the child Neovim!")

  local self = setmetatable({
    bufnr = bufnr,
    chan = chan,
    repo = repo,
    tmp = tmp,
  }, Session)

  self:wait_for("%[No Name%]", 10000)

  return self
end

---Send keys to the child, exactly as if they were typed.
---@param keys string
function Session:send(keys)
  vim.fn.chansend(self.chan, api.nvim_replace_termcodes(keys, true, true, true))
end

---Send keys, then wait for the screen to settle.
---@param keys string
---@param settle? integer
function Session:type(keys, settle)
  self:send(keys)
  self:sleep(settle or 250)
end

---@param ms integer
function Session:sleep(ms)
  vim.wait(ms, function() return false end)
end

---The text that is currently on the child's screen.
---@return string
function Session:screen()
  return table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n")
end

---The screen, with all runs of whitespace collapsed. Handy for matching
---content whose alignment depends on the width of the window.
---@return string
function Session:flat_screen()
  return (self:screen():gsub("[ \t]+", " "))
end

---Wait until `pattern` shows up on the child's screen.
---@param pattern string
---@param timeout? integer
---@return boolean ok
function Session:wait_for(pattern, timeout)
  return vim.wait(timeout or 5000, function()
    return self:screen():find(pattern) ~= nil
  end, 50)
end

---Wait until `pattern` is gone from the child's screen.
---@param pattern string
---@param timeout? integer
---@return boolean ok
function Session:wait_until_gone(pattern, timeout)
  return vim.wait(timeout or 5000, function()
    return self:screen():find(pattern) == nil
  end, 50)
end

---@param ... string
---@return string[] stdout
---@return integer code
function Session:git(...)
  return M.git(self.repo, ...)
end

---@param path string
---@return string[]
function Session:read(path)
  return vim.fn.readfile(self.repo .. "/" .. path)
end

function Session:stop()
  pcall(vim.fn.chanclose, self.chan)
  pcall(vim.fn.jobstop, self.chan)
  vim.wait(2000, function() return vim.fn.jobwait({ self.chan }, 0)[1] ~= -1 end, 50)
  if self.tmp then vim.fn.delete(self.tmp, "rf") end
end

M.Session = Session

return M
