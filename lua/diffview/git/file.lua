local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

---@module "plenary.async"
local async = lazy.require("plenary.async")
---@type Rev
local Rev = lazy.access("diffview.git.rev", "Rev")
---@type ERevType
local RevType = lazy.access("diffview.git.rev", "RevType")
---@module "diffview.config"
local config = lazy.require("diffview.config")
---@module "diffview.git.utils"
local git = lazy.require("diffview.git.utils")
---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

---@type PathLib
local pl = lazy.access(utils, "path")

local api = vim.api
local M = {}

---@alias git.FileDataProducer fun(kind: git.FileKind, path: string, pos: "left"|"right"): string[]

---@class git.File : diffview.Object
---@field git_ctx GitContext
---@filed path string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field kind "working"|"staged"
---@field nulled boolean
---@field rev Rev
---@field commit Commit?
---@field symbol string?
---@field get_data git.FileDataProducer?
---@field bufnr integer
---@field binary boolean
---@field active boolean
---@field ready boolean
---@field winopts WindowOptions
local File = oop.create_class("git.File")

---@static
---@type integer|nil
File._null_buffer = nil

---@type table<integer, boolean>
File.attached = {}

---@static
File.bufopts = {
  buftype = "nowrite",
  modifiable = false,
  swapfile = false,
  bufhidden = "hide",
  undolevels = -1,
}

---File constructor
---@param opt table
function File:init(opt)
  self.git_ctx = opt.git_ctx
  self.path = opt.path
  self.absolute_path = pl:absolute(opt.path, opt.git_ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path)
  self.kind = opt.kind
  self.nulled = not not opt.nulled
  self.rev = opt.rev
  self.commit = opt.commit
  self.symbol = opt.symbol
  self.get_data = opt.get_data
  self.active = false
  self.ready = false

  self.winopts = {
    diff = true,
    scrollbind = true,
    cursorbind = true,
    foldmethod = "diff",
    scrollopt = { "ver", "hor", "jump" },
    foldcolumn = "1",
    foldlevel = 0,
    foldenable = true,
  }
end

---@param force? boolean Also delete buffers for LOCAL files.
function File:destroy(force)
  self.active = false
  self:detach_buffer()

  if force or self.rev.type ~= RevType.LOCAL then
    File.safe_delete_buf(self.bufnr)
  end
end

function File:post_buf_created()
  api.nvim_buf_call(self.bufnr, function()
    DiffviewGlobal.emitter:emit("diff_buf_read", self.bufnr)
  end)
end

---@param callback function
function File:create_buffer(callback)
  if self.binary == nil and not config.get_config().diff_binaries then
    self.binary = git.is_binary(self.git_ctx.toplevel, self.path, self.rev)
  end

  if self.nulled or self.binary then
    self.bufnr = File._get_null_buffer()
    self:post_buf_created()
    vim.schedule(callback)
    return self.bufnr
  end

  if self.rev.type == RevType.LOCAL then
    self.bufnr = utils.find_file_buffer(self.absolute_path)

    if not self.bufnr then
      local winid = utils.temp_win()
      assert(winid ~= 0, "Failed to create temporary window!")

      api.nvim_win_call(winid, function()
        vim.cmd("edit " .. vim.fn.fnameescape(self.absolute_path))
        self.bufnr = api.nvim_get_current_buf()
        vim.bo[self.bufnr].bufhidden = "hide"
      end)

      api.nvim_win_close(winid, true)
    end

    self:post_buf_created()
    vim.schedule(callback)
    return self.bufnr
  end

  self.bufnr = api.nvim_create_buf(false, false)

  local context
  if self.rev.type == RevType.COMMIT then
    context = self.rev:abbrev(11)
  elseif self.rev.type == RevType.STAGE then
    context = (":%d:"):format(self.rev.stage)
  elseif self.rev.type == RevType.CUSTOM then
    context = "[custom]"
  end

  for option, value in pairs(File.bufopts) do
    api.nvim_buf_set_option(self.bufnr, option, value)
  end

  local fullname = pl:join("diffview://", self.git_ctx.dir, context, self.path)
  local ok = pcall(api.nvim_buf_set_name, self.bufnr, fullname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    repeat
      fullname = pl:join("diffview://", self.git_ctx.dir, context, i, self.path)
      ok = pcall(api.nvim_buf_set_name, self.bufnr, fullname)
      i = i + 1
    until ok
  end

  local function data_callback(lines)
    vim.schedule(function()
      if api.nvim_buf_is_valid(self.bufnr) then
        vim.bo[self.bufnr].modifiable = true
        api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        api.nvim_buf_call(self.bufnr, function()
          vim.cmd("filetype detect")
        end)
        vim.bo[self.bufnr].modifiable = false
        self:post_buf_created()
        callback()
      end
    end)
  end

  if self.get_data and vim.is_callable(self.get_data) then
    async.run(function()
      local pos = self.symbol == "a" and "left" or "right"
      local data = self.get_data(self.kind, self.path, pos)
      data_callback(data)
      ---@diagnostic disable-next-line: param-type-mismatch
    end, nil)

  else
    git.show(
      self.git_ctx.toplevel,
      { ("%s:%s"):format(self.rev:object_name() or "", self.path) },
      function(err, result)
        if err then
          utils.err(string.format("Failed to create diff buffer: '%s'", fullname), true)
          return
        end

        data_callback(result)
      end
    )
  end

  return self.bufnr
end

function File:is_valid()
  return self.bufnr and api.nvim_buf_is_valid(self.bufnr)
end

---@param force? boolean
function File:attach_buffer(force)
  if self.bufnr then
    File._attach_buffer(self.bufnr, force)
  end
end

---@param force? boolean
function File:detach_buffer(force)
  if self.bufnr then
    File._detach_buffer(self.bufnr, force)
  end
end

function File:dispose_buffer()
  if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
    File._detach_buffer(self.bufnr)
    File.safe_delete_buf(self.bufnr)
    self.bufnr = nil
  end
end

---@static
---@param bufnr integer
---@param force? boolean
function File._attach_buffer(bufnr, force)
  if force or not File.attached[bufnr] then
    local conf = config.get_config()
    local default_opt = { silent = true, nowait = true, buffer = bufnr }

    for lhs, mapping in pairs(conf.keymaps.view) do
      if type(lhs) == "number" then
        local opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = bufnr })
        vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
      else
        vim.keymap.set("n", lhs, mapping, default_opt)
      end
    end

    File.attached[bufnr] = true
  end
end

---@static
---@param bufnr integer
---@param force? boolean
function File._detach_buffer(bufnr, force)
  if force or File.attached[bufnr] then
    local conf = config.get_config()

    for lhs, mapping in pairs(conf.keymaps.view) do
      if type(lhs) == "number" then
        local modes = type(mapping[1]) == "table" and mapping[1] or { mapping[1] }
        for _, mode in ipairs(modes) do
          pcall(api.nvim_buf_del_keymap, bufnr, mode, mapping[2])
        end
      else
        pcall(api.nvim_buf_del_keymap, bufnr, "n", lhs)
      end
    end

    File.attached[bufnr] = nil
  end
end

function File.safe_delete_buf(bufnr)
  if not bufnr or bufnr == File._null_buffer or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  for _, winid in ipairs(utils.win_find_buf(bufnr, 0)) do
    File.load_null_buffer(winid)
  end

  pcall(api.nvim_buf_delete, bufnr, { force = true })
end

---@static Get the bufid of the null buffer. Create it if it's not loaded.
---@return integer
function File._get_null_buffer()
  if not (File._null_buffer and api.nvim_buf_is_loaded(File._null_buffer)) then
    local bn = api.nvim_create_buf(false, false)
    for option, value in pairs(File.bufopts) do
      api.nvim_buf_set_option(bn, option, value)
    end

    local bufname = "diffview://null"
    local ok = pcall(api.nvim_buf_set_name, bn, bufname)
    if not ok then
      utils.wipe_named_buffer(bufname)
      api.nvim_buf_set_name(bn, bufname)
    end

    File._null_buffer = bn
  end

  return File._null_buffer
end

---@static
function File.load_null_buffer(winid)
  local bn = File._get_null_buffer()
  api.nvim_win_set_buf(winid, bn)
  File._attach_buffer(bn)
end

---@type git.File
File.NULL_FILE = File({
  git_ctx = {
    toplevel = "diffview://",
  },
  path = "null",
  kind = "working",
  status = "X",
  nulled = true,
  rev = Rev.new_null_tree(),
})

M.File = File
return M
