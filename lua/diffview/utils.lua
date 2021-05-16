local api = vim.api
local M = {}

local path_sep = package.config:sub(1,1)

function M._echo_multiline(msg)
  for _, s in ipairs(vim.fn.split(msg, "\n")) do
    vim.cmd("echom '" .. s:gsub("'", "''").."'")
  end
end

function M.info(msg)
  vim.cmd('echohl Directory')
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd('echohl None')
end

function M.warn(msg)
  vim.cmd('echohl WarningMsg')
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd('echohl None')
end

function M.err(msg)
  vim.cmd('echohl ErrorMsg')
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd('echohl None')
end

function M.clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

function M.shell_error()
  return vim.v.shell_error ~= 0
end

function M.path_to_matching_str(path)
  return path:gsub('(%-)', '(%%-)'):gsub('(%.)', '(%%.)'):gsub('(%_)', '(%%_)')
end

function M.path_join(paths)
  return table.concat(paths, path_sep)
end

function M.path_split(path)
  return path:gmatch('[^'..path_sep..']+'..path_sep..'?')
end

---Get the basename of the given path.
---@param path string
---@return string
function M.path_basename(path)
  path = M.path_remove_trailing(path)
  local i = path:match("^.*()" .. path_sep)
  if not i then return path end
  return path:sub(i + 1, #path)
end

function M.path_extension(path)
  path = M.path_basename(path)
  return path:match(".+%.(.*)")
end

---Get the path to the parent directory of the given path. Returns `nil` if the
---path has no parent.
---@param path string
---@param remove_trailing boolean
---@return string|nil
function M.path_parent(path, remove_trailing)
  path = " " .. M.path_remove_trailing(path)
  local i = path:match("^.+()" .. path_sep)
  if not i then return nil end
  path = path:sub(2, i)
  if remove_trailing then
    path = M.path_remove_trailing(path)
  end
  return path
end

---Get a path relative to another path.
---@param path string
---@param relative_to string
---@return string
function M.path_relative(path, relative_to)
  local p, _ = path:gsub("^" .. M.path_to_matching_str(M.path_add_trailing(relative_to)), "")
  return p
end

function M.path_add_trailing(path)
  if path:sub(-1) == path_sep then
    return path
  end

  return path..path_sep
end

function M.path_remove_trailing(path)
  local p, _ = path:gsub(path_sep..'$', '')
  return p
end

function M.path_shorten(path, max_length)
  if string.len(path) > max_length - 1 then
    path = path:sub(string.len(path) - max_length + 1, string.len(path))
    local i = path:match("()" .. path_sep)
    if not i then
      return "…" .. path
    end
    return "…" .. path:sub(i, -1)
  else
    return path
  end
end

function M.str_right_pad(s, min_size, fill)
  local result = s
  if not fill then fill = " " end

  while #result < min_size do
    result = result .. fill
  end

  return result
end

function M.str_left_pad(s, min_size, fill)
  local result = s
  if not fill then fill = " " end

  while #result < min_size do
    result = fill .. result
  end

  return result
end

function M.str_center_pad(s, min_size, fill)
  local result = s
  if not fill then fill = " " end

  while #result < min_size do
    if #result % 2 == 0 then
      result = result .. fill
    else
      result = fill .. result
    end
  end

  return result
end

function M.str_shorten(s, new_length)
  if string.len(s) > new_length - 1 then
    return "…" .. s:sub(string.len(s) - new_length + 1, string.len(s))
  end
  return s
end

---Get the output of a system command.
---WARN: As of NVIM v0.5.0-dev+1320-gba04b3d83, `io.popen` causes rendering
---artifacts if the command fails.
---@param cmd string
---@return string
function M.system(cmd)
  local pfile = io.popen(cmd)
  if not pfile then return end
  local data = pfile:read("*a")
  io.close(pfile)

  return data
end

---Get the output of a system command as a list of lines.
---WARN: As of NVIM v0.5.0-dev+1320-gba04b3d83, `io.popen` causes rendering
---artifacts if the command fails.
---@param cmd string
---@return string[]
function M.system_list(cmd)
  local pfile = io.popen(cmd)
  if not pfile then return end

  local lines = {}
  for line in pfile:lines() do
    table.insert(lines, line)
  end
  io.close(pfile)

  return lines
end

---Enum creator
---@param t string[]
---@return table<string, integer>
function M.enum(t)
  for i, v in ipairs(t) do
    t[v] = i
  end
  return t
end

---@class Object -- Base class
local Object = {}
Object.__index = Object

function Object:new()
  return setmetatable({}, self)
end

function Object:class()
  return Object
end

function Object:super()
  return nil
end

function Object:instanceof(other)
  return other == Object
end

function M.class(super_class)
  super_class = super_class or Object
  local new_class = {}
  local class_mt = { __index = new_class }
  new_class.__index = new_class

  setmetatable(new_class, super_class)

  function new_class:new()
    return setmetatable({}, class_mt)
  end

  ---Get the class object.
  ---@return table
  function new_class:class()
    return new_class
  end

  ---Get the super class.
  ---@return table
  function new_class:super()
    return super_class
  end

  function new_class:instanceof(other)
    local cur = new_class
    while cur do
      if cur == other then
        return true
      end
      cur = cur:super()
    end
    return false
  end

  return new_class
end

---Create a shallow copy of a portion of a list.
---@param t table
---@param first integer First index, inclusive
---@param last integer Last index, inclusive
---@return any[]
function M.tbl_slice(t, first, last)
  local slice = {}
  for i = first, last or #t, 1 do
    table.insert(slice, t[i])
  end

  return slice
end

function M.tbl_concat(a, b)
  local result = {}
  for i, v in ipairs(a) do
    result[i] = v
  end
  for i, v in ipairs(b) do
    result[#a + i] = v
  end

  return result
end

function M.tbl_deep_clone(t)
  if not t then return end
  local clone = {}

  for k, v in pairs(t) do
    if type(v) == "table" then
      clone[k] = M.tbl_deep_clone(v)
    else
      clone[k] = v
    end
  end

  return clone
end

function M.tbl_pack(...)
  return {n=select('#',...); ...}
end

function M.tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or #t)
end

function M.find_named_buffer(name)
  for _, v in ipairs(api.nvim_list_bufs()) do
    if vim.fn.bufname(v) == name then
      return v
    end
  end
  return nil
end

function M.wipe_named_buffer(name)
  local bn = M.find_named_buffer(name)
  if bn then
    local win_ids = vim.fn.win_findbuf(bn)
    for _, id in ipairs(win_ids) do
      if vim.fn.win_gettype(id) ~= "autocmd" then
        api.nvim_win_close(id, true)
      end
    end

    api.nvim_buf_set_name(bn, "")
    vim.schedule(function ()
      pcall(api.nvim_buf_delete, bn, {})
    end)
  end
end

local function merge(t, first, mid, last, comparator)
  local n1 = mid - first + 1
  local n2 = last - mid
  local ls = M.tbl_slice(t, first, mid)
  local rs = M.tbl_slice(t, mid + 1, last)
  local i = 1
  local j = 1
  local k = first

  while (i <= n1 and j <= n2) do
    if comparator(ls[i], rs[j]) then
      t[k] = ls[i]
      i = i + 1
    else
      t[k] = rs[j]
      j = j + 1
    end
    k = k + 1
  end

  while i <= n1 do
    t[k] = ls[i]
    i = i + 1
    k = k + 1
  end

  while j <= n2 do
    t[k] = rs[j]
    j = j + 1
    k = k + 1
  end
end

local function split_merge(t, first, last, comparator)
  if (last - first) < 1 then return end

  local mid = math.floor((first + last) / 2)

  split_merge(t, first, mid, comparator)
  split_merge(t, mid + 1, last, comparator)
  merge(t, first, mid, last, comparator)
end

---Perform a merge sort on a given list.
---@param t any[]
---@param comparator function|nil
function M.merge_sort(t, comparator)
  if not comparator then
    comparator = function (a, b)
      return a < b
    end
  end

  split_merge(t, 1, #t, comparator)
end

M.path_sep = path_sep

return M
