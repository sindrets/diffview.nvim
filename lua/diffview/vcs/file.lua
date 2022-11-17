local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local GitRev = lazy.access("diffview.vcs.adapters.git.rev", "GitRev") ---@type GitRev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local async = lazy.require("plenary.async") ---@module "plenary.async"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local pl = lazy.access(utils, "path") ---@type PathLib|LazyModule

local api = vim.api
local M = {}

---@alias git.FileDataProducer fun(kind: git.FileKind, path: string, pos: "left"|"right"): string[]

---@class vcs.File : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field kind git.FileKind
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
local File = oop.create_class("vcs.File")

---@type table<integer, vcs.File.AttachState>
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
  self.adapter = opt.adapter
  self.path = opt.path
  self.absolute_path = pl:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path)
  self.kind = opt.kind
  self.binary = utils.sate(opt.binary)
  self.nulled = not not opt.nulled
  self.rev = opt.rev
  self.commit = opt.commit
  self.symbol = opt.symbol
  self.get_data = opt.get_data
  self.active = false
  self.ready = false

  self.winopts = opt.winopts or {
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
  local view = require("diffview.lib").get_current_view()

  if view then
    view.emitter:on("diff_buf_win_enter", function(bufnr, winid)
      if bufnr == self.bufnr then
        api.nvim_win_call(winid, function()
          DiffviewGlobal.emitter:emit("diff_buf_read", self.bufnr)
        end)

        return true
      end
    end)
  end
end

---@param callback function
function File:create_buffer(callback)
  if self == File.NULL_FILE then
    vim.schedule(callback)
    return File._get_null_buffer()
  elseif self:is_valid() then
    vim.schedule(callback)
    return self.bufnr
  end

  if self.binary == nil and not config.get_config().diff_binaries then
    self.binary = self.adapter:is_binary(self.path, self.rev)
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
    else
      -- NOTE: LSP servers might load buffers in the background and unlist
      -- them. Explicitly set the buffer as listed when loading it here.
      vim.bo[self.bufnr].buflisted = true
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

  local fullname = pl:join("diffview://", self.adapter.ctx.dir, context, self.path)
  local ok = pcall(api.nvim_buf_set_name, self.bufnr, fullname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    repeat
      fullname = pl:join("diffview://", self.adapter.ctx.dir, context, i, self.path)
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
    vcs.show(
      self.adapter,
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
---@param opt? vcs.File.AttachState
function File:attach_buffer(force, opt)
  if self.bufnr then
    File._attach_buffer(self.bufnr, force, opt)
  end
end

function File:detach_buffer()
  if self.bufnr then
    File._detach_buffer(self.bufnr)
  end
end

function File:dispose_buffer()
  if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
    File._detach_buffer(self.bufnr)
    File.safe_delete_buf(self.bufnr)
    self.bufnr = nil
  end
end

---@param t1 table
---@param t2 table
---@return vcs.File.AttachState
local function prepare_attach_opt(t1, t2)
  local res = vim.tbl_extend("keep", t1, {
    keymaps = {},
    disable_diagnostics = false,
  })

  for k, v in pairs(t2) do
    local t = type(res[k])

    if t == "boolean" then
      res[k] = res[k] or v
    elseif t == "table" and type(v) == "table" then
      res[k] = vim.tbl_extend("force", res[k], v)
    else
      res[k] = v
    end
  end

  return res
end

---@class vcs.File.AttachState
---@field keymaps table
---@field disable_diagnostics boolean

---@static
---@param bufnr integer
---@param force? boolean
---@param opt? vcs.File.AttachState
function File._attach_buffer(bufnr, force, opt)
  local new_opt = false
  local cur_state = File.attached[bufnr] or {}
  local state = prepare_attach_opt(cur_state, opt or {})

  if opt then
    new_opt = not vim.deep_equal(cur_state or {}, opt)
  end

  if force or new_opt or not cur_state then
    local conf = config.get_config()

    -- Keymaps
    state.keymaps = utils.tbl_deep_union_extend(conf.keymaps.view, state.keymaps)
    local default_map_opt = { silent = true, nowait = true, buffer = bufnr }

    for lhs, mapping in pairs(state.keymaps) do
      if type(lhs) == "number" then
        local map_opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = bufnr })
        vim.keymap.set(mapping[1], mapping[2], mapping[3], map_opt)
      else
        vim.keymap.set("n", lhs, mapping, default_map_opt)
      end
    end

    -- Diagnostics
    if state.disable_diagnostics then
      vim.diagnostic.disable(bufnr)
    end

    File.attached[bufnr] = state
  end
end

---@static
---@param bufnr integer
function File._detach_buffer(bufnr)
  local state = File.attached[bufnr]

  if state then
    -- Keymaps
    for lhs, mapping in pairs(state.keymaps) do
      if type(lhs) == "number" then
        local modes = type(mapping[1]) == "table" and mapping[1] or { mapping[1] }
        for _, mode in ipairs(modes) do
          pcall(api.nvim_buf_del_keymap, bufnr, mode, mapping[2])
        end
      else
        pcall(api.nvim_buf_del_keymap, bufnr, "n", lhs)
      end
    end

    -- Diagnostics
    if state.disable_diagnostics then
      vim.diagnostic.enable(bufnr)
    end

    File.attached[bufnr] = nil
  end
end

function File.safe_delete_buf(bufnr)
  if not bufnr or bufnr == File.NULL_FILE.bufnr or not api.nvim_buf_is_loaded(bufnr) then
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
  if not api.nvim_buf_is_loaded(File.NULL_FILE.bufnr or -1) then
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

    File.NULL_FILE.bufnr = bn
  end

  return File.NULL_FILE.bufnr
end

---@static
function File.load_null_buffer(winid)
  local bn = File._get_null_buffer()
  api.nvim_win_set_buf(winid, bn)
  File._attach_buffer(bn)
end

---@type vcs.File
File.NULL_FILE = File({
  -- NOTE: consider changing this adapter to be an actual adapter instance
  adapter = {
    ctx = {
      toplevel = "diffview://",
    },
  },
  path = "null",
  kind = "working",
  status = "X",
  binary = false,
  nulled = true,
  rev = GitRev.new_null_tree(),
})

M.File = File
return M
