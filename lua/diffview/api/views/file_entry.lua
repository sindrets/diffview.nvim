local oop = require("diffview.oop")
local utils = require("diffview.utils")
local async = require("plenary.async")
local FileEntry = require("diffview.views.file_entry").FileEntry
local RevType = require("diffview.git.rev").RevType
local api = vim.api

local M = {}

---@class CFileEntry : FileEntry
---@field left_null boolean
---@field right_null boolean
---@field get_file_data function
local CFileEntry = oop.create_class("CFileEntry", FileEntry)

---CFileEntry constructor.
---@param opt any
---@return CFileEntry
function CFileEntry:init(opt)
  self.super:init(opt)
  self.left_binary = opt.left_binary
  self.right_binary = opt.right_binary
  self.left_null = opt.left_null
  self.right_null = opt.right_null
  self.get_file_data = opt.get_file_data
end

---@Override
function CFileEntry:load_buffers(git_root, left_winid, right_winid, callback)
  local splits = {
    {
      winid = left_winid,
      bufid = self.left_bufid,
      rev = self.left,
      pos = "left",
      producer = function()
        return self.get_file_data(self.kind, self.path, "left")
      end,
      null = self.left_null == true,
      ready = false,
    },
    {
      winid = right_winid,
      bufid = self.right_bufid,
      rev = self.right,
      pos = "right",
      producer = function()
        return self.get_file_data(self.kind, self.path, "right")
      end,
      null = self.right_null == true,
      ready = false,
    },
  }

  local function on_ready_factory(split)
    return function()
      split.ready = true
      local was_ready = self[split.pos .. "_ready"]
      self[split.pos .. "_ready"] = true

      if splits[1].ready and splits[2].ready then

        -- Load and set the buffer
        for _, sp in ipairs(splits) do
          if sp.load then
            sp.load()
          else
            api.nvim_win_set_buf(sp.winid, sp.bufid)
          end
        end

        CFileEntry._update_windows(left_winid, right_winid)

        -- Call hooks
        for _, sp in ipairs(splits) do
          api.nvim_win_call(sp.winid, function()
            if not was_ready then
              DiffviewGlobal.emitter:emit("diff_buf_read", sp.bufid)
            end
            DiffviewGlobal.emitter:emit("diff_buf_win_enter", sp.bufid)
          end)
        end

        if type(callback) == "function" then
          callback()
        end
      end
    end
  end

  self.left_ready = self.left_bufid and api.nvim_buf_is_loaded(self.left_bufid)
  self.right_ready = self.right_bufid and api.nvim_buf_is_loaded(self.right_bufid)


  if not (self.left_ready and self.right_ready) then
    utils.no_win_event_call(function()
      CFileEntry.load_null_buffer(left_winid)
      CFileEntry.load_null_buffer(right_winid)
    end)
  end

  utils.no_win_event_call(function()
    for _, split in ipairs(splits) do
      local on_ready = on_ready_factory(split)

      if not (split.bufid and api.nvim_buf_is_loaded(split.bufid)) then
        if split.rev.type == RevType.LOCAL then
          if split.null or CFileEntry.should_null(split.rev, self.status, split.pos) then
            local bn = CFileEntry._create_buffer(
              git_root,
              split.rev,
              self.path,
              split.producer,
              true,
              on_ready
            )
            split.bufid = bn
            CFileEntry._attach_buffer(split.bufid)
          else
            -- Load local file
            split.load = function()
              api.nvim_win_call(split.winid, function()
                vim.cmd("edit " .. vim.fn.fnameescape(self.absolute_path))
                split.bufid = api.nvim_get_current_buf()
                CFileEntry._save_winopts(split.bufid, split.winid)
                self[split.pos .. "_bufid"] = split.bufid
                CFileEntry._attach_buffer(split.bufid)
              end)
            end
            on_ready()
          end
        elseif
          vim.tbl_contains({ RevType.COMMIT, RevType.INDEX, RevType.CUSTOM }, split.rev.type)
        then
          -- Load custom file data
          local bn
          if self.oldpath and split.pos == "left" then
            bn = CFileEntry._create_buffer(
              git_root,
              split.rev,
              self.oldpath,
              split.producer,
              split.null,
              on_ready
            )
          else
            bn = CFileEntry._create_buffer(
              git_root,
              split.rev,
              self.path,
              split.producer,
              split.null or CFileEntry.should_null(split.rev, self.status, split.pos),
              on_ready
            )
          end
          table.insert(self.created_bufs, bn)
          split.bufid = bn
          CFileEntry._attach_buffer(split.bufid)
        end
      else
        -- Buffer already exists
        CFileEntry._attach_buffer(split.bufid)
        on_ready()
      end
    end
  end)

  self.left_bufid = splits[1].bufid
  self.right_bufid = splits[2].bufid
  vim.cmd("do WinEnter")
end

---@static
---@Override
function CFileEntry._create_buffer(git_root, rev, path, producer, null, callback)
  if null or type(producer) ~= "function" then
    callback()
    return CFileEntry._get_null_buffer()
  end

  local bn = api.nvim_create_buf(false, false)

  local context
  if rev.type == RevType.COMMIT then
    context = rev:abbrev(11)
  elseif rev.type == RevType.INDEX then
    context = ":0:"
  elseif rev.type == RevType.CUSTOM then
    context = "[diff]"
  end

  -- stylua: ignore
  local fullname = utils.path:join("diffview://", git_root, ".git", context, path)
  for option, value in pairs(FileEntry.bufopts) do
    api.nvim_buf_set_option(bn, option, value)
  end

  local ok = pcall(api.nvim_buf_set_name, bn, fullname)
  if not ok then
    -- Resolve name conflict
    local i = 1
    while not ok do
      -- stylua: ignore
      fullname = utils.path:join("diffview://", git_root, ".git", context, i, path)
      ok = pcall(api.nvim_buf_set_name, bn, fullname)
      i = i + 1
    end
  end

  async.run(function()
    -- TODO: Update api to be properly async
    local result = producer()
    vim.schedule(function()
      if api.nvim_buf_is_valid(bn) then
        vim.bo[bn].modifiable = true
        api.nvim_buf_set_lines(bn, 0, -1, false, result or {})
        vim.bo[bn].modifiable = false
        vim.api.nvim_buf_call(bn, function()
          vim.cmd("filetype detect")
        end)
        callback()
      end
    end)
  end, nil)

  return bn
end

M.CFileEntry = CFileEntry
return M
