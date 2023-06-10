local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await
local fmt = string.format
local uv = vim.loop

local M = {}

local is_windows = uv.os_uname().version:match("Windows")

local function handle_uv_err(x, err, err_msg)
  if not x then
    error(err .. " " .. err_msg, 2)
  end

  return x
end

-- Ref: https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats
local WINDOWS_PATH_SPECIFIER = {
  dos_dev = "^[\\/][\\/][.?][\\/]", -- DOS Device path
  unc = "^[\\/][\\/]", -- UNC path
  rel_drive = "^[\\/]", -- Relative drive
  drive = [[^[a-zA-Z]:]],
}
table.insert(WINDOWS_PATH_SPECIFIER, WINDOWS_PATH_SPECIFIER.dos_dev)
table.insert(WINDOWS_PATH_SPECIFIER, WINDOWS_PATH_SPECIFIER.unc)
table.insert(WINDOWS_PATH_SPECIFIER, WINDOWS_PATH_SPECIFIER.rel_drive)
table.insert(WINDOWS_PATH_SPECIFIER, WINDOWS_PATH_SPECIFIER.drive)

---@class PathLib
---@operator call : PathLib
---@field sep "/"|"\\"
---@field os "unix"|"windows" Determines the type of paths we're dealing with.
---@field cwd string Leave as `nil` to always use current cwd.
local PathLib = oop.create_class("PathLib")

function PathLib:init(o)
  self.os = o.os or (is_windows and "windows" or "unix")
  assert(vim.tbl_contains({ "unix", "windows" }, self.os), "Invalid OS type!")
  self._is_windows = self.os == "windows"
  self.sep = o.separator or (self._is_windows and "\\" or "/")
  self.cwd = o.cwd and self:convert(o.cwd) or nil
end

---@private
function PathLib:_cwd()
  return self.cwd or self:convert(uv.cwd())
end

---@private
---@return ...
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

  return unpack(paths, 1, argc)
end

---@private
---@param path string
function PathLib:_split_root(path)
  local root = self:root(path)
  if not root then return "", path end
  return root, path:sub(#root + 1)
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
---@param sep? "/"|"\\"
---@return string
function PathLib:convert(path, sep)
  sep = sep or self.sep
  local prefix
  local p = tostring(path)

  if self:is_uri(path) then
    sep = "/"
    prefix, p = path:match("^(%w+://)(.*)")
  elseif self._is_windows then
    for _, pat in ipairs(WINDOWS_PATH_SPECIFIER) do
      prefix = path:match(pat)

      if prefix then
        prefix = prefix:gsub("[\\/]", sep)
        p = path:sub(#prefix + 1)
        break
      end
    end
  end

  p, _ = p:gsub("[\\/]+", sep)

  return (prefix or "") .. p
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
    for _, pat in ipairs(WINDOWS_PATH_SPECIFIER) do
      if path:match(pat) ~= nil then return true end
    end

    return false
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
  path = self:expand(path)
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
  path = self:remove_trailing(self:_clean(path))

  if self:is_abs(path) then
    if self._is_windows then
      for _, pat in ipairs(WINDOWS_PATH_SPECIFIER) do
        local prefix = path:match(pat)
        if prefix and #path == #prefix then return true end
      end

      return false
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
      for _, pat in ipairs(WINDOWS_PATH_SPECIFIER) do
        local root = path:match(pat)
        if root then return root end
      end
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

    if self._is_windows and root == root:match(WINDOWS_PATH_SPECIFIER.rel_drive) then
      -- Resolve relative drive
      -- path="/foo/bar/baz", cwd="D:/lorem/ipsum" -> "D:/foo/bar/baz"
      root = self:root(cwd)
    end
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

---Expand environment variables and `~`.
---@param path string
---@return string
function PathLib:expand(path)
  local segments = self:explode(path)
  local idx = 1

  if segments[1] == "~" then
    segments[1] = uv.os_homedir()
    idx = 2
  end

  for i = idx, #segments do
    local env_var = segments[i]:match("^%$(%S+)$")
    if env_var then
      segments[i] = uv.os_getenv(env_var) or env_var
    end
  end

  return self:join(unpack(segments))
end

---Joins an ordered list of path segments into a path string.
---@vararg ... string|string[] Paths
---@return string
function PathLib:join(...)
  local segments = { ... }

  if type(segments[1]) == "table" then
    segments = segments[1]
  end

  local ret = ""

  for i = 1, table.maxn(segments) do
    local cur = segments[i]
    if cur and cur ~= "" then
      if #ret > 0 and not ret:sub(-1, -1):match("[\\/]") then
        ret = ret .. self.sep
      end
      ret = ret .. cur
    end
  end

  return self:_clean(ret)
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

  local root
  root, path = self:_split_root(path)

  if root ~= "" then
    parts[i] = root

    if path:sub(1, 1) == self.sep then
      path = path:sub(2)
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
  local root
  root, path = self:_split_root(path)

  if #path == 0 then return root .. path end
  if path:sub(-1) == self.sep then
    return root .. path
  end

  return root .. path .. self.sep
end

---Remove any trailing separator, if present.
---@param path string
---@return string
function PathLib:remove_trailing(path)
  local root
  root, path = self:_split_root(path)
  local p, _ = path:gsub(self.sep .. "$", "")

  return root .. p
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
---@return string?
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
function PathLib:truncate(path, max_length)
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
---@param nosuf? boolean
---@param list falsy
---@return string
---@overload fun(self: PathLib, path: string, nosuf: boolean, list: true): string[]
function PathLib:vim_expand(path, nosuf, list)
  if list then
    return vim.tbl_map(function(v)
      return self:convert(v)
    end, vim.fn.expand(path, nosuf, list))
  end

  return self:convert(vim.fn.expand(path, nosuf, list) --[[@as string ]])
end

---@param path string
---@return string
function PathLib:vim_fnamemodify(path, mods)
  return self:convert(vim.fn.fnamemodify(path, mods))
end

---@param path string
---@return table?
function PathLib:stat(path)
  return uv.fs_stat(path)
end

---@param path string
---@return string?
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
function PathLib:is_dir(path)
  return self:type(path) == "directory"
end

---Check for read access to a given path.
---@param path string
---@return boolean
function PathLib:readable(path)
  local p = uv.fs_realpath(path)

  if p then
    return not not uv.fs_access(p, "R")
  end

  return false
end

---@class PathLib.touch.Opt
---@field mode? integer
---@field parents? boolean

---@param self PathLib
---@param path string
---@param opt PathLib.touch.Opt
PathLib.touch = async.void(function(self, path, opt)
  opt = opt or {}
  local mode = opt.mode or tonumber("0644", 8)

  path = self:_clean(path)
  local stat = self:stat(path)

  if stat then
    -- Path exists: just update utime
    local time = os.time()
    handle_uv_err(uv.fs_utime(path, time, time))
    return
  end

  if opt.parents then
    local parent = self:parent(path)

    if parent then
      await(self:mkdir(self:parent(path), { parents = true }))
    end
  end

  local fd = handle_uv_err(uv.fs_open(path, "w", mode))
  handle_uv_err(uv.fs_close(fd))
end)

---@class PathLib.mkdir.Opt
---@field mode? integer
---@field parents? boolean

---@param self PathLib
---@param path string
---@param opt? table
PathLib.mkdir = async.void(function(self, path, opt)
  opt = opt or {}
  local mode = opt.mode or tonumber("0700", 8)
  path = self:absolute(path)

  if not opt.parents then
    handle_uv_err(uv.fs_mkdir(path, mode))
    return
  end

  local cur_path

  for _, part in ipairs(self:explode(path)) do
    cur_path = cur_path and self:join(cur_path, part) or part
    local stat = self:stat(cur_path)

    if not stat then
      handle_uv_err(uv.fs_mkdir(cur_path, mode))
    else
      if stat.type ~= "directory" then
        error(fmt("Cannot create directory '%s': Not a directory", cur_path))
      end
    end
  end
end)

---Delete a name and possibly the file it refers to.
---@param self PathLib
---@param path string
---@param callback? function
---@diagnostic disable-next-line: unused-local
PathLib.unlink = async.wrap(function(self, path, callback)
  ---@cast callback -?
  uv.fs_unlink(path, function(err, ok)
    if not ok then
      error(err)
    end
    callback()
  end)
end)

function PathLib:chain(...)
  local t = {
    __result = utils.tbl_pack(...)
  }

  return setmetatable(t, {
    __index = function(chain, k)
      if k == "get" then
        return function(_)
          return utils.tbl_unpack(t.__result)
        end

      else
        return function(_, ...)
          t.__result = utils.tbl_pack(self[k](self, utils.tbl_unpack(t.__result), ...))
          return chain
        end
      end
    end
  })
end

M.PathLib = PathLib
return M
