local M = {}

local path_sep = package.config:sub(1,1)

function M.info(msg)
  vim.cmd('echohl Directory')
  vim.cmd("echom '[Difftool.nvim] "..msg:gsub("'", "''").."'")
  vim.cmd('echohl None')
end

function M.warn(msg)
  vim.cmd('echohl WarningMsg')
  vim.cmd("echom '[Difftool.nvim] "..msg:gsub("'", "''").."'")
  vim.cmd('echohl None')
end

function M.err(msg)
  vim.cmd('echohl ErrorMsg')
  vim.cmd("echom '[Difftool.nvim] "..msg:gsub("'", "''").."'")
  vim.cmd('echohl None')
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

---Get the output of a system command.
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
---@return table
function M.enum(t)
  for i, v in ipairs(t) do
    t[v] = i
  end
  return t
end

M.path_sep = path_sep

return M
