local async = require("plenary.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local M = {}

local uv = vim.loop
local is_windows = uv.os_uname().version:match("Windows")

---@class PathLib
---@field sep '"/"'|'"\\\\"'
---@field os '"unix"'|'"windows"' Determines the type of paths we're dealing with.
---@field cwd string Leave as `nil` to always use current cwd.
local PathLib = oop.create_class("PathLib")

function PathLib:init(o)
  self.sep = o.separator or package.config:sub(1, 1)
  self.os = o.os or (is_windows and "windows" or "unix")
  self._is_windows = self.os == "windows"
  self.cwd = o.cwd and self:convert(o.cwd) or nil
end

function PathLib:_cwd()
  return self.cwd or self:convert(uv.cwd())
end

---@return string
function PathLib:_clean(...)
  local argc = select("#", ...)
  if argc == 1 and select(1, ...) ~= nil then
    return self:convert(...)
  end
  local paths = { ... }
  for i = 1, argc do
    if paths[i] ~= nil then
      paths[i] = self:convert(paths[i])
    end
  end
  return unpack(paths)
end

---Check if a given path is a URI.
---@param path string
---@return boolean
function PathLib:is_uri(path)
  return string.match(path, "^%w+://") ~= nil
end

---Get the URI scheme of a given URI.
---@param path string
---@return string
function PathLib:get_uri_scheme(path)
  return string.match(path, "^(%w+://)")
end

---Change the path separators in a path. Removes duplicate separators.
---@param path string
---@param sep? '"/"'|'"\\\\"'
---@return string
function PathLib:convert(path, sep)
  sep = sep or self.sep
  local scheme, p = "", tostring(path)
  if self:is_uri(path) then
    scheme, p = path:match("^(%w+://)(.*)")
  end
  p, _ = p:gsub("[\\/]+", sep)
  return scheme .. p
end

---Convert a path to use the appropriate path separators for the current OS.
---@param path string
---@return string
function PathLib:to_os(path)
  return self:convert(path, self._is_windows and "\\" or "/")
end

---Check if a given path is absolute.
---@param path string
---@return boolean
function PathLib:is_abs(path)
  path = self:_clean(path)
  if self._is_windows then
    return path:match("^[A-Z]:") ~= nil
  else
    return path:sub(1, 1) == self.sep
  end
end

---Get the absolute path of a given path. This is resolved using either the
---`cwd` field if it's defined. Otherwise the current cwd is used instead.
---@param path string
---@param cwd? string
---@return string
function PathLib:absolute(path, cwd)
  path, cwd = self:_clean(path, cwd)
  cwd = cwd or self:_cwd()
  if self:is_uri(path) then
    return path
  end
  if self:is_abs(path) then
    return self:normalize(path, { cwd = cwd, absolute = true })
  end
  return self:normalize(self:join(cwd, path), { cwd = cwd, absolute = true })
end

---Check if the given path is the root.
---@param path string
---@return boolean
function PathLib:is_root(path)
  path = self:_clean(path)
  if self:is_abs(path) then
    if self._is_windows then
      return path:match(("^([A-Z]:%s?$)"):format(self.sep)) ~= nil
    else
      return path == self.sep
    end
  end
  return false
end

---Get the root of an absolute path. Returns nil if the path is not absolute.
---@param path string
---@return string|nil
function PathLib:root(path)
  path = tostring(path)
  if self:is_abs(path) then
    if self._is_windows then
      return path:match("^([A-Z]:)")
    else
      return self.sep
    end
  end
end

---@class PathLibNormalizeSpec
---@field cwd string
---@field absolute boolean

---Normalize a given path, resolving relative segments.
---@param path string
---@param opt? PathLibNormalizeSpec
---@return string
function PathLib:normalize(path, opt)
  path = self:_clean(path)
  if self:is_uri(path) then
    return path
  end

  opt = opt or {}
  local cwd = opt.cwd and self:_clean(opt.cwd) or self:_cwd()
  local absolute = vim.F.if_nil(opt.absolute, false)

  local root = self:root(path)
  if root and self:is_root(path) then
    return path
  end

  if not self:is_abs(path) then
    local relpath = self:relative(path, cwd, true)
    path = self:add_trailing(cwd) .. relpath
  end

  local parts = self:explode(path)
  if root then
    table.remove(parts, 1)
  end

  local normal = path
  if #parts > 1 then
    local i = 2
    local upc = 0
    repeat
      if parts[i] == "." then
        table.remove(parts, i)
        i = i - 1
      elseif parts[i] == ".." then
        if i == 1 then
          upc = upc + 1
        end
        table.remove(parts, i)
        if i > 1 then
          table.remove(parts, i - 1)
          i = i - 2
        else
          i = i - 1
        end
      end

      i = i + 1
    until i > #parts

    normal = self:join(root, unpack(parts))
    if not absolute and upc == 0 then
      normal = self:relative(normal, cwd, true)
    end
  end

  return normal == "" and "." or normal
end

---Joins an ordered list of path segments into a path string.
---@vararg ... string|string[] Paths
---@return string
function PathLib:join(...)
  local segments = { ... }
  if type(segments[1]) == "table" then
    segments = segments[1]
  end
  segments = { self:_clean(unpack(segments)) }
  local argc = select("#", unpack(segments))
  local result = ""
  local idx = 1

  if self:is_uri(segments[idx] or "") then
    result = segments[idx]
    idx = idx + 1
  end

  if not self._is_windows and segments[idx] == self.sep then
    result = result .. self.sep
    idx = idx + 1
  end

  local segc = 0
  for i = idx, argc do
    if segments[i] ~= nil and segments[i] ~= "" then
      result = result
      .. (segc > 0 and self.sep or "")
      .. string.match(segments[i], [[^(.-)[/\]?$]])
      segc = segc + 1
    end
  end

  return result
end

---Explodes the path into an ordered list of path segments.
---@param path string
---@return string[]
function PathLib:explode(path)
  path = self:_clean(path)
  local parts = {}
  local i = 1

  if self:is_uri(path) then
    local scheme, p = path:match("^(%w+://)(.*)")
    parts[i] = scheme
    path = p
    i = i + 1
  end

  local root = self:root(path)
  if root then
    parts[i] = root
    if self._is_windows then
      path = path:sub(#root + #self.sep + 1, -1)
    else
      path = path:sub(#root + 1, -1)
    end
  end

  for part in path:gmatch(string.format("([^%s]+)%s?", self.sep, self.sep)) do
    parts[#parts+1] = part
  end

  return parts
end

---Add a trailing separator, unless already present.
---@param path string
---@return string
function PathLib:add_trailing(path)
  path = tostring(path)
  if path:sub(-1) == self.sep then
    return path
  end

  return path .. self.sep
end

---Remove any trailing separator, if present.
---@param path string
---@return string
function PathLib:remove_trailing(path)
  path = tostring(path)
  local p, _ = path:gsub(self.sep .. "$", "")
  return p
end

---Get the basename of the given path.
---@param path string
---@return string
function PathLib:basename(path)
  path = self:remove_trailing(self:_clean(path))
  local i = path:match("^.*()" .. self.sep)
  if not i then
    return path
  end
  return path:sub(i + 1, #path)
end

---Get the extension of the given path.
---@param path string
---@return string|nil
function PathLib:extension(path)
  path = self:basename(path)
  return path:match(".+%.(.*)")
end

---Get the path to the parent directory of the given path. Returns `nil` if the
---path has no parent.
---@param path string
---@param n? integer Nth parent. (default: 1)
---@return string|nil
function PathLib:parent(path, n)
  if type(n) ~= "number" or n < 1 then
    n = 1
  end
  local parts = self:explode(path)
  local root = self:root(path)
  if root and n == #parts then
    return root
  elseif n >= #parts then
    return
  end
  return self:join(unpack(parts, 1, #parts - n))
end

---Get a path relative to another path.
---@param path string
---@param relative_to string
---@param no_resolve? boolean Don't normalize paths first.
---@return string
function PathLib:relative(path, relative_to, no_resolve)
  path, relative_to = self:_clean(path, relative_to)
  if not no_resolve then
    local abs = self:is_abs(path)
    path = self:normalize(path, { absolute = abs })
    relative_to = self:normalize(relative_to, { absolute = abs })
  end
  if relative_to == "" then
    return path
  elseif relative_to == path then
    return ""
  end
  local p, _ = path:gsub("^" .. vim.pesc(self:add_trailing(relative_to)), "")
  return p
end

---Shorten a path by truncating the head.
---@param path string
---@param max_length integer
---@return string
function PathLib:shorten(path, max_length)
  path = self:_clean(path)
  if #path > max_length - 1 then
    path = path:sub(#path - max_length + 1, #path)
    local i = path:match("()" .. self.sep)
    if not i then
      return "…" .. path
    end
    return "…" .. path:sub(i, -1)
  else
    return path
  end
end

---@param path string
---@return string|nil
function PathLib:realpath(path)
  local p = uv.fs_realpath(path)
  if p then
    return self:convert(p)
  end
end

---@param path string
---@return string|nil
function PathLib:readlink(path)
  local p = uv.fs_readlink(path)
  if p then
    return self:convert(p)
  end
end

---@param path string
---@return string
function PathLib:vim_expand(path)
  return self:convert(vim.fn.expand(path))
end

---@param path string
---@return string
function PathLib:vim_fnamemodify(path, mods)
  return self:convert(vim.fn.fnamemodify(path, mods))
end

---@param path string
---@return table|nil
function PathLib:stat(path)
  return uv.fs_stat(path)
end

---@param path string
---@return string|nil
function PathLib:type(path)
  local p = uv.fs_realpath(path)
  if p then
    local stat = uv.fs_stat(p)
    if stat then
      return stat.type
    end
  end
end

---@param path string
---@return boolean
function PathLib:is_directory(path)
  return self:type(path) == "directory"
end

---Check for read access to a given path.
---@param path string
---@return boolean
function PathLib:readable(path)
  local p = uv.fs_realpath(path)
  if p then
    return uv.fs_access(p, "R")
  end
  return false
end

---Delete a name and possibly the file it refers to.
---@param self PathLib
---@param path string
---@param callback function
---@return string err, boolean ok
---@diagnostic disable-next-line: unused-local
PathLib.unlink = async.wrap(function(self, path, callback)
  uv.fs_unlink(path, function(err, ok)
    callback(ok, err)
  end)
end, 3)

function PathLib:chain(...)
  local t = {
    _result = utils.tbl_pack(...)
  }

  return setmetatable(t, {
    __index = function(chain, k)
      if k == "get" then
        return function(_)
          return utils.tbl_unpack(t._result)
        end

      else
        return function(_, ...)
          t._result = utils.tbl_pack(self[k](self, utils.tbl_unpack(t._result), ...))
          return chain
        end
      end
    end
  })
end

M.PathLib = PathLib
return M
