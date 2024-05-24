local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local GitRev = lazy.access("diffview.vcs.adapters.git.rev", "GitRev") ---@type GitRev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await
local fmt = string.format
local pl = lazy.access(utils, "path") ---@type PathLib

local api = vim.api
local M = {}

local HAS_NVIM_0_10 = vim.fn.has("nvim-0.10") == 1

---@alias git.FileDataProducer fun(kind: vcs.FileKind, path: string, pos: "left"|"right"): string[]

---@class CustomFolds
---@field type string
---@field [integer] { [1]: integer, [2]: integer }

---@class vcs.File : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field kind vcs.FileKind
---@field nulled boolean
---@field rev Rev
---@field blob_hash string?
---@field commit Commit?
---@field symbol string?
---@field get_data git.FileDataProducer?
---@field bufnr integer
---@field binary boolean
---@field active boolean
---@field ready boolean
---@field winbar string?
---@field winopts WindowOptions
---@field custom_folds? CustomFolds
local File = oop.create_class("vcs.File")

---@type table<integer, vcs.File.AttachState>
File.attached = {}

---@type table<string, table<string, integer>>
File.index_bufmap = {}

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
    winhl = {
      "DiffAdd:DiffviewDiffAdd",
      "DiffDelete:DiffviewDiffDelete",
      "DiffChange:DiffviewDiffChange",
      "DiffText:DiffviewDiffText",
    },
  }

  -- Set winbar info
  if self.rev then
    local winbar, label

    if self.rev.type == RevType.LOCAL then
      winbar = " WORKING TREE - ${path}"
    elseif self.rev.type == RevType.COMMIT then
      winbar = " ${object_path}"
    elseif self.rev.type == RevType.STAGE then
      if self.kind == "conflicting" then
        label = ({
          [1] = "(Common ancestor) ",
          [2] = "(Current changes) ",
          [3] = "(Incoming changes) ",
        })[self.rev.stage] or ""
      end

      winbar = " INDEX ${label}- ${object_path}"
    end

    if winbar then
      self.winbar = utils.str_template(winbar, {
        path = self.path,
        object_path = self.rev:object_name(10) .. ":" .. self.path,
        label = label or "",
      })
    end
  end
end

---@param force? boolean Also delete buffers for LOCAL files.
function File:destroy(force)
  self.active = false
  self:detach_buffer()

  if force or self.rev.type ~= RevType.LOCAL and not lib.is_buf_in_use(self.bufnr, { self }) then
    File.safe_delete_buf(self.bufnr)
  end
end

function File:post_buf_created()
  local view = require("diffview.lib").get_current_view()

  if view then
    view.emitter:on("diff_buf_win_enter", function(_, bufnr, winid, ctx)
      if bufnr == self.bufnr then
        api.nvim_win_call(winid, function()
          DiffviewGlobal.emitter:emit("diff_buf_read", self.bufnr, ctx)
        end)

        return true
      end
    end)
  end
end

function File:_create_local_buffer()
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
end

---@private
---@param self vcs.File
---@param callback (fun(err?: string[], data?: string[]))
File.produce_data = async.wrap(function(self, callback)
  if self.get_data and vim.is_callable(self.get_data) then
    local pos = self.symbol == "a" and "left" or "right"
    local data = self.get_data(self.kind, self.path, pos)
    callback(nil, data)
  else
    local err, data = await(self.adapter:show(self.path, self.rev))

    if err then
      callback(err)
      return
    end

    callback(nil, data)
  end
end)

---@param self vcs.File
---@param callback function
File.create_buffer = async.wrap(function(self, callback)
  ---@diagnostic disable: invisible
  await(async.scheduler())

  if self == File.NULL_FILE then
    callback(File._get_null_buffer())
    return
  elseif self:is_valid() then
    callback(self.bufnr)
    return
  end

  if self.binary == nil and not config.get_config().diff_binaries then
    self.binary = self.adapter:is_binary(self.path, self.rev)
  end

  if self.nulled or self.binary then
    self.bufnr = File._get_null_buffer()
    self:post_buf_created()
    callback(self.bufnr)
    return
  end

  if self.rev.type == RevType.LOCAL then
    self:_create_local_buffer()
    callback(self.bufnr)
    return
  end

  local context
  if self.rev.type == RevType.COMMIT then
    context = self.rev:abbrev(11)
  elseif self.rev.type == RevType.STAGE then
    context = fmt(":%d:", self.rev.stage)
  elseif self.rev.type == RevType.CUSTOM then
    context = "[custom]"
  end

  local fullname = pl:join("diffview://", self.adapter.ctx.dir, context, self.path)

  self.bufnr = utils.find_named_buffer(fullname)

  if self.bufnr then
    callback(self.bufnr)
    return
  end

  -- Create buffer and set name *before* calling `produce_data()` to ensure
  -- that multiple file instances won't ever try to create the same file.
  self.bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(self.bufnr, fullname)

  local err, lines = await(self:produce_data())
  if err then error(table.concat(err, "\n")) end

  await(async.scheduler())

  -- Revalidate buffer in case the file was destroyed before `produce_data()`
  -- returned.
  if not api.nvim_buf_is_valid(self.bufnr) then
    error("The buffer has been invalidated!")
    return
  end
  local bufopts = vim.deepcopy(File.bufopts)

  if self.rev.type == RevType.STAGE and self.rev.stage == 0 then
    self.blob_hash = self.adapter:file_blob_hash(self.path)
    bufopts.modifiable = true
    bufopts.buftype = nil
    bufopts.undolevels = nil
    utils.tbl_set(File.index_bufmap, { self.adapter.ctx.toplevel, self.path }, self.bufnr)

    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = self.bufnr,
      nested = true,
      callback = function()
        self.adapter:stage_index_file(self)
      end,
    })
  end

  for option, value in pairs(bufopts) do
    api.nvim_buf_set_option(self.bufnr, option, value)
  end

  local last_modifiable = vim.bo[self.bufnr].modifiable
  local last_modified = vim.bo[self.bufnr].modified
  vim.bo[self.bufnr].modifiable = true
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  api.nvim_buf_call(self.bufnr, function()
    vim.cmd("filetype detect")
  end)

  vim.bo[self.bufnr].modifiable = last_modifiable
  vim.bo[self.bufnr].modified = last_modified
  self:post_buf_created()
  callback(self.bufnr)
  ---@diagnostic enable: invisible
end)

function File:is_valid()
  return self.bufnr and api.nvim_buf_is_valid(self.bufnr)
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

---@param force? boolean
---@param opt? vcs.File.AttachState
function File:attach_buffer(force, opt)
  if self.bufnr then
    local new_opt = false
    local cur_state = File.attached[self.bufnr] or {}
    local state = prepare_attach_opt(cur_state, opt or {})

    if opt then
      new_opt = not vim.deep_equal(cur_state or {}, opt)
    end

    if force or new_opt or not cur_state then
      local conf = config.get_config()

      -- Keymaps
      state.keymaps = config.extend_keymaps(conf.keymaps.view, state.keymaps)
      local default_map_opt = { silent = true, nowait = true, buffer = self.bufnr }

      for _, mapping in ipairs(state.keymaps) do
        local map_opt = vim.tbl_extend("force", default_map_opt, mapping[4] or {}, { buffer = self.bufnr })
        vim.keymap.set(mapping[1], mapping[2], mapping[3], map_opt)
      end

      -- Diagnostics
      if state.disable_diagnostics then
        if HAS_NVIM_0_10 then
          vim.diagnostic.enable(false, { bufnr = self.bufnr })
        else
          ---@diagnostic disable-next-line: deprecated
          vim.diagnostic.disable(self.bufnr)
        end
      end

      File.attached[self.bufnr] = state
    end
  end
end

function File:detach_buffer()
  if self.bufnr then
    local state = File.attached[self.bufnr]

    if state then
      -- Keymaps
      for lhs, mapping in pairs(state.keymaps) do
        if type(lhs) == "number" then
          local modes = type(mapping[1]) == "table" and mapping[1] or { mapping[1] }
          for _, mode in ipairs(modes) do
            pcall(api.nvim_buf_del_keymap, self.bufnr, mode, mapping[2])
          end
        else
          pcall(api.nvim_buf_del_keymap, self.bufnr, "n", lhs)
        end
      end

      -- Diagnostics
      if state.disable_diagnostics then
        if HAS_NVIM_0_10 then
          vim.diagnostic.enable(true, { bufnr = self.bufnr })
        else
          ---@diagnostic disable-next-line: param-type-mismatch
          vim.diagnostic.enable(self.bufnr)
        end
      end

      File.attached[self.bufnr] = nil
    end
  end
end

function File:dispose_buffer()
  if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
    self:detach_buffer()

    if not lib.is_buf_in_use(self.bufnr, { self }) then
      File.safe_delete_buf(self.bufnr)
    end

    self.bufnr = nil
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
  File.NULL_FILE:attach_buffer()
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
