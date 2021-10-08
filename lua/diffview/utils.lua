local api = vim.api
local M = {}

local is_windows = jit.os == "Windows"
local mapping_callbacks = {}
local path_sep = package.config:sub(1, 1)
local setlocal_opr_templates = {
  set = [[setl ${option}=${value}]],
  append = [[exe 'setl ${option}=' . (&${option} == "" ? "" : &${option} . ",") . '${value}']],
  prepend = [[exe 'setl ${option}=${value}' . (&${option} == "" ? "" : "," . &${option})]],
}

function M._echo_multiline(msg)
  for _, s in ipairs(vim.fn.split(msg, "\n")) do
    vim.cmd("echom '" .. s:gsub("'", "''") .. "'")
  end
end

function M.info(msg)
  vim.cmd("echohl Directory")
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd("echohl None")
end

function M.warn(msg)
  vim.cmd("echohl WarningMsg")
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd("echohl None")
end

function M.err(msg)
  vim.cmd("echohl ErrorMsg")
  M._echo_multiline("[Diffview.nvim] " .. msg)
  vim.cmd("echohl None")
end

---Call the function `f`, ignoring most of the window and buffer related
---events. The function is called in protected mode.
---@param f function
---@return boolean success
---@return any result Return value
function M.no_win_event_call(f)
  local last = vim.opt.eventignore._value
  vim.opt.eventignore:prepend(
    "WinEnter,WinLeave,WinNew,WinClosed,BufWinEnter,BufWinLeave,BufEnter,BufLeave"
  )
  local ok, err = pcall(f)
  vim.opt.eventignore = last
  return ok, err
end

function M.clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

function M.sign(n)
  return (n > 0 and 1 or 0) - (n < 0 and 1 or 0)
end

function M.shell_error()
  return vim.v.shell_error ~= 0
end

---Escape a string for use as a pattern.
---@param s string
---@return string
function M.pattern_esc(s)
  local result = string.gsub(s, "[%(|%)|%%|%[|%]|%-|%.|%?|%+|%*|%^|%$]", {
    ["%"] = "%%",
    ["-"] = "%-",
    ["("] = "%(",
    [")"] = "%)",
    ["."] = "%.",
    ["["] = "%[",
    ["]"] = "%]",
    ["?"] = "%?",
    ["+"] = "%+",
    ["*"] = "%*",
    ["^"] = "%^",
    ["$"] = "%$",
  })
  return result
end

---Check if a given path is absolute.
---@param path string
---@return boolean
function M.path_is_abs(path)
  if is_windows then
    return path:match([[^%a:\]]) ~= nil
  else
    return path:sub(1, 1) == "/"
  end
end

---Joins an ordered list of path segments into a path string.
---@param paths string[]
---@return string
function M.path_join(paths)
  local result = paths[1]
  for i = 2, #paths do
    if tostring(paths[i]):sub(1, 1) == path_sep then
      result = result .. paths[i]
    else
      result = result .. path_sep .. paths[i]
    end
  end
  return result
end

---Explodes the path into an ordered list of path segments.
---@param path string
---@return string[]
function M.path_explode(path)
  local parts = {}
  for part in path:gmatch(string.format("([^%s]+)%s?", path_sep, path_sep)) do
    table.insert(parts, part)
  end
  return parts
end

---Get the basename of the given path.
---@param path string
---@return string
function M.path_basename(path)
  path = M.path_remove_trailing(path)
  local i = path:match("^.*()" .. path_sep)
  if not i then
    return path
  end
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
  if not i then
    return nil
  end
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
  local p, _ = path:gsub("^" .. M.pattern_esc(M.path_add_trailing(relative_to)), "")
  return p
end

function M.path_add_trailing(path)
  if path:sub(-1) == path_sep then
    return path
  end

  return path .. path_sep
end

function M.path_remove_trailing(path)
  local p, _ = path:gsub(path_sep .. "$", "")
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
  if not fill then
    fill = " "
  end

  while #result < min_size do
    result = result .. fill
  end

  return result
end

function M.str_left_pad(s, min_size, fill)
  local result = s
  if not fill then
    fill = " "
  end

  while #result < min_size do
    result = fill .. result
  end

  return result
end

function M.str_center_pad(s, min_size, fill)
  local result = s
  if not fill then
    fill = " "
  end

  while #result < min_size do
    if #result % 2 == 0 then
      result = result .. fill
    else
      result = fill .. result
    end
  end

  return result
end

function M.str_shorten(s, max_length, head)
  if string.len(s) > max_length then
    if head then
      return "…" .. s:sub(string.len(s) - max_length + 1, string.len(s))
    end
    return s:sub(1, max_length - 1) .. "…"
  end
  return s
end

function M.str_split(s, sep)
  sep = sep or "%s+"
  local iter = s:gmatch("()" .. sep .. "()")
  local result = {}
  local sep_start, sep_end

  local i = 1
  while i ~= nil do
    sep_start, sep_end = iter()
    table.insert(result, s:sub(i, (sep_start or 0) - 1))
    i = sep_end
  end

  return result
end

---Simple string templating
---Example template: "${name} is ${value}"
---@param str string Template string
---@param table table Key-value pairs to replace in the string
function M.str_template(str, table)
  return (str:gsub("($%b{})", function(w)
    return table[w:sub(3, -2)] or w
  end))
end

---Get the output of a system command.
---WARN: As of NVIM v0.5.0-dev+1320-gba04b3d83, `io.popen` causes rendering
---artifacts if the command fails.
---@param cmd string
---@return string
function M.system(cmd)
  local pfile = io.popen(cmd)
  if not pfile then
    return
  end
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
  if not pfile then
    return
  end

  local lines = {}
  for line in pfile:lines() do
    table.insert(lines, line)
  end
  io.close(pfile)

  return lines
end

---HACK: workaround for inconsistent behavior from `vim.opt_local`.
---@see [Neovim issue](https://github.com/neovim/neovim/issues/14670)
---@param winids number[]|number Either a list of winids, or a single winid (0 for current window).
---@param option string
---@param value string[]|string
---@param opt table
---`opt` fields:
---   - `restore_cursor` (boolean) Return the cursor to the initial window. (default: `true`)
---   - `method` ("set"|"append"|"prepend") Assignment method. (default: "set")
function M.set_local(winids, option, value, opt)
  local cmd
  opt = vim.tbl_extend("keep", opt or {}, {
    method = "set",
  })

  if type(value) == "boolean" then
    cmd = string.format("setl %s%s", value and "" or "no", option)
  else
    value = (type(value) == "table" and table.concat(value, ",") or tostring(value)):gsub("'", "''")
    cmd = M.str_template(setlocal_opr_templates[opt.method], { option = option, value = value })
  end

  if type(winids) ~= "table" then
    winids = { winids }
  end

  local ok, err = M.no_win_event_call(function()
    for _, id in ipairs(winids) do
      api.nvim_win_call(id, function()
        vim.cmd(cmd)
      end)
    end
  end)

  if not ok then
    error(err)
  end
end

function M.tabnr_to_id(tabnr)
  for _, id in ipairs(api.nvim_list_tabpages()) do
    if api.nvim_tabpage_get_number(id) == tabnr then
      return id
    end
  end
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

function M.tbl_concat(...)
  local result = {}
  local n = 0

  for _, t in ipairs({ ... }) do
    for i, v in ipairs(t) do
      result[n + i] = v
    end
    n = n + #t
  end

  return result
end

function M.tbl_deep_clone(t)
  if not t then
    return
  end
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

function M.tbl_deep_equals(t1, t2)
  if not (t1 and t2) then
    return false
  end

  local function recurse(t11, t22)
    if #t11 ~= #t22 then
      return false
    end

    local seen = {}
    for key, value in pairs(t11) do
      seen[key] = true
      if type(value) == "table" then
        if type(t22[key]) ~= "table" then
          return false
        end
        if not recurse(value, t22[key]) then
          return false
        end
      else
        if not (value == t22[key]) then
          return false
        end
      end
    end

    for key, _ in pairs(t22) do
      if not seen[key] then
        return false
      end
    end

    return true
  end

  return recurse(t1, t2)
end

function M.tbl_pack(...)
  return { n = select("#", ...), ... }
end

function M.tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or #t)
end

function M.tbl_indexof(t, v)
  for i, vt in ipairs(t) do
    if vt == v then
      return i
    end
  end
  return -1
end

function M.tbl_clear(t)
  for k, _ in pairs(t) do
    t[k] = nil
  end
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
    vim.schedule(function()
      pcall(api.nvim_buf_delete, bn, {})
    end)
  end
end

function M.find_file_buffer(path)
  local p = vim.fn.fnamemodify(path, ":p")
  for _, id in ipairs(vim.api.nvim_list_bufs()) do
    if p == vim.api.nvim_buf_get_name(id) then
      return id
    end
  end
end

---Get a list of all windows that contain the given buffer.
---@param bufid integer
---@return integer[]
function M.win_find_buf(bufid)
  local result = {}
  local wins = api.nvim_list_wins()

  for _, id in ipairs(wins) do
    if api.nvim_win_get_buf(id) == bufid then
      table.insert(result, id)
    end
  end

  return result
end

---Get a list of all windows in the given tabpage that contains the given
---buffer.
---@param tabpage integer
---@param bufid integer
---@return integer[]
function M.tabpage_win_find_buf(tabpage, bufid)
  local result = {}
  local wins = api.nvim_tabpage_list_wins(tabpage)

  for _, id in ipairs(wins) do
    if api.nvim_win_get_buf(id) == bufid then
      table.insert(result, id)
    end
  end

  return result
end

function M.clear_prompt()
  vim.cmd("norm! :esc<CR>")
end

function M.input_char(prompt)
  if prompt then
    print(prompt)
  end
  local c
  while type(c) ~= "number" do
    c = vim.fn.getchar()
  end
  M.clear_prompt()
  return vim.fn.nr2char(c)
end

function M.input(prompt, default, completion)
  local v = vim.fn.input({
    prompt = prompt,
    default = default,
    completion = completion,
    cancelreturn = "__INPUT_CANCELLED__",
  })
  M.clear_prompt()
  return v
end

local function prepare_mapping(t)
  local default_options = { noremap = true, silent = true }
  if type(t[4]) ~= "table" then
    t[4] = {}
  end
  local opts = vim.tbl_extend("force", default_options, t.opt or t[4])
  local rhs
  if type(t[3]) == "function" then
    mapping_callbacks[#mapping_callbacks + 1] = t[3]
    rhs = string.format(
      "<Cmd>lua require('diffview.utils')._mapping_callbacks[%d]()<CR>",
      #mapping_callbacks
    )
  else
    assert(type(t[3]) == "string", "The rhs of the mapping must be either a string or a function!")
    rhs = t[3]
  end

  return { t[1], t[2], rhs, opts }
end

function M.map(t)
  local prepared = prepare_mapping(t)
  vim.api.nvim_set_keymap(prepared[1], prepared[2], prepared[3], prepared[4])
end

function M.buf_map(bufid, t)
  local prepared = prepare_mapping(t)
  vim.api.nvim_buf_set_keymap(bufid, prepared[1], prepared[2], prepared[3], prepared[4])
end

local function merge(t, first, mid, last, comparator)
  local n1 = mid - first + 1
  local n2 = last - mid
  local ls = M.tbl_slice(t, first, mid)
  local rs = M.tbl_slice(t, mid + 1, last)
  local i = 1
  local j = 1
  local k = first

  while i <= n1 and j <= n2 do
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
  if (last - first) < 1 then
    return
  end

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
    comparator = function(a, b)
      return a < b
    end
  end

  split_merge(t, 1, #t, comparator)
end

M._mapping_callbacks = mapping_callbacks
M.path_sep = path_sep

return M
