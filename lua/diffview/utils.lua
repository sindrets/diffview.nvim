local lazy = require("diffview.lazy")

---@module "plenary.job"
local Job = lazy.require("plenary.job", function(m)
  -- Ensure plenary's `new` method will use the right metatable when this is
  -- invoked as a method.
  local new = m.new
  function m.new(_, ...)
    return new(m, ...)
  end
  return m
end)
---@module "plenary.async"
local async = lazy.require("plenary.async")

local api = vim.api
local M = {}

---@class vector<T> : { [integer]: T }

local mapping_callbacks = {}
local path_sep = package.config:sub(1, 1)

---@type PathLib
M.path = lazy.require("diffview.path", function(module)
  return module.PathLib({ separator = "/" })
end)

---Echo string with multiple lines.
---@param msg string|string[]
---@param hl? string Highlight group name.
---@param schedule? boolean Schedule the echo call.
function M.echo_multiln(msg, hl, schedule)
  if schedule then
    vim.schedule(function()
      M.echo_multiln(msg, hl, false)
    end)
    return
  end

  vim.cmd("echohl " .. (hl or "None"))
  if type(msg) ~= "table" then
    msg = { msg }
  end
  for _, chunk in ipairs(msg) do
    for _, line in ipairs(vim.split(chunk, "\n", { trimempty = false })) do
      line = line:gsub('["|\t]', { ['"'] = [[\"]], ["\t"] = "        " })
      vim.cmd(string.format('echom "%s"', line))
    end
  end
  vim.cmd("echohl None")
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.info(msg, schedule)
  if type(msg) ~= "table" then
    msg = { msg }
  end
  if not msg[1] or (msg[1] == "" and #msg == 1) then
    return
  end
  msg = M.vec_slice(msg)
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "Directory", schedule)
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.warn(msg, schedule)
  if type(msg) ~= "table" then
    msg = { msg }
  end
  if not msg[1] or (msg[1] == "" and #msg == 1) then
    return
  end
  msg = M.vec_slice(msg)
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "WarningMsg", schedule)
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.err(msg, schedule)
  if type(msg) ~= "table" then
    msg = { msg }
  end
  if not msg[1] or (msg[1] == "" and #msg == 1) then
    return
  end
  msg = M.vec_slice(msg)
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "ErrorMsg", schedule)
end

---Call the function `f`, ignoring most of the window and buffer related
---events. The function is called in protected mode.
---@param f function
---@return boolean success
---@return any result Return value
function M.no_win_event_call(f)
  local last = vim.o.eventignore
  ---@diagnostic disable-next-line: undefined-field
  vim.opt.eventignore:prepend(
    "WinEnter,WinLeave,WinNew,WinClosed,BufWinEnter,BufWinLeave,BufEnter,BufLeave"
  )
  local ok, err = pcall(f)
  vim.opt.eventignore = last
  return ok, err
end

---Update a given window by briefly setting it as the current window.
---@param winid integer
function M.update_win(winid)
  local cur_winid = api.nvim_get_current_win()
  if cur_winid ~= winid then
    local ok, err = M.no_win_event_call(function()
      api.nvim_set_current_win(winid)
      api.nvim_set_current_win(cur_winid)
    end)
    if not ok then
      error(err)
    end
  end
end

---Pick the argument at the given index. A negative number is indexed from the
---end (`-1` is the last argument).
---@param index integer
---@param ... unknown
---@return unknown
function M.pick(index, ...)
  local args = { ... }

  if index < 0 then
    index = #args + index + 1
  end

  return args[index]
end

---Get the first non-nil value among the given arguments.
---@param ... unknown
---@return unknown?
function M.sate(...)
  local args = { ... }

  for i = 1, select("#", ...) do
    if args[i] ~= nil then
      return args[i]
    end
  end
end

---Clamp a given value between a min and a max value.
---@param value number
---@param min number
---@param max number
---@return number
function M.clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

---Get the sign of a given number.
---@param n number
---@return -1|0|1
function M.sign(n)
  return (n > 0 and 1 or 0) - (n < 0 and 1 or 0)
end

---@param s string
---@param min_size integer
---@param fill string? (default: `" "`)
function M.str_right_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  return s .. string.rep(fill, math.ceil((min_size - #s) / #fill))
end

---@param s string
---@param min_size integer
---@param fill string? (default: `" "`)
function M.str_left_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  return string.rep(fill, math.ceil((min_size - #s) / #fill)) .. s
end

---@param s string
---@param min_size integer
---@param fill string? (default: ` `)
function M.str_center_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  local left_len = math.floor((min_size - #s) / #fill / 2)
  local right_len = math.ceil((min_size - #s) / #fill / 2)
  return string.rep(fill, left_len) .. s .. string.rep(fill, right_len)
end

---Truncate the tail of a given string with ellipsis if it exceeds the max
---length.
---@param s string
---@param max_length integer
---@param head boolean Truncate the head rather than the tail.
---@return string
function M.str_shorten(s, max_length, head)
  if string.len(s) > max_length then
    if head then
      return "…" .. s:sub(string.len(s) - max_length + 1, string.len(s))
    end
    return s:sub(1, max_length - 1) .. "…"
  end
  return s
end

---@param s string
---@param sep? string (default: `%s+`)
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

---Match a given string against multiple patterns.
---@param str string
---@param patterns string[]
---@return ... captured: The first match, or `nil` if no patterns matched.
function M.str_match(str, patterns)
  for _, pattern in ipairs(patterns) do
    local m = { str:match(pattern) }
    if #m > 0 then
      return unpack(m)
    end
  end
end

---@class utils.str_quote.Opt
---@field esc_fmt string Format string for escaping quotes. Passed to `string.format()`.
---@field prefer_single boolean Prefer single quotes.
---@field only_if_whitespace boolean Only quote the string if it contains whitespace.

---@param s string
---@param opt? utils.str_quote.Opt
function M.str_quote(s, opt)
  ---@cast opt utils.str_quote.Opt
  s = tostring(s)
  opt = vim.tbl_extend("keep", opt or {}, {
    esc_fmt = [[\%s]],
    prefer_single = false,
    only_if_whitespace = false,
  }) --[[@as utils.str_quote.Opt ]]

  if opt.only_if_whitespace and not s:find("%s") then
    return s
  end

  local primary, secondary = [["]], [[']]
  if opt.prefer_single then
    primary, secondary = [[']], [["]]
  end

  local has_primary = s:find(primary) ~= nil
  local has_secondary = s:find(secondary) ~= nil

  if has_primary and not has_secondary then
    return secondary .. s .. secondary
  else
    local esc = opt.esc_fmt:format(primary)
    -- First un-escape already escaped quotes to avoid incorrectly applied escapes.
    s, _ = s:gsub(vim.pesc(esc), primary)
    s, _ = s:gsub(primary, esc)
    return primary .. s .. primary
  end
end

---@class utils.handle_job.Opt
---@field fail_on_empty boolean Consider the job as failed if the code is 0 and stdout is empty.
---@field log_func function|string
---@field context string Context for the logger.
---@field debug_opt LogJobSpec

---Handles logging of failed jobs. If the given job hasn't failed, this does nothing.
---@param job Job
---@param opt? utils.handle_job.Opt
function M.handle_job(job, opt)
  ---@cast job Job|{ [string]: any }

  opt = opt or {}
  local empty = false
  if opt.fail_on_empty then
    local out = job:result()
    empty = not (out[2] ~= nil or out[1] and out[1] ~= "")
  end

  if job.code == 0 and not empty then
    if opt.debug_opt then
      require("diffview.logger").log_job(job, opt.debug_opt)
    end
    return
  end

  local logger = require("diffview.logger")
  local log_func = logger.s_error

  if type(opt.log_func) == "string" then
    log_func = logger[opt.log_func]
  elseif type(opt.log_func) == "function" then
    log_func = opt.log_func --[[@as function ]]
  end

  local args = vim.tbl_map(function(arg)
    return ("'%s'"):format(arg:gsub("'", [['"'"']]))
  end, job.args) --[[@as string[] ]]

  local msg
  local context = opt.context and ("[%s] "):format(opt.context) or ""
  if empty and job.code == 0 then
    msg = ("%sJob expected output, but returned nothing! Code: %s"):format(context, job.code)
  else
    msg = ("%sJob exited with a non-zero exit status! Code: %s"):format(context, job.code)
  end

  log_func(msg)
  log_func(("%s   [cmd] %s %s"):format(context, job.command, table.concat(args, " ")))

  if job._raw_cwd then
    log_func(("%s   [cwd] %s"):format(context, job._raw_cwd))
  end

  local stderr = job:stderr_result()
  if #stderr > 0 then
    log_func(("%s[stderr] %s"):format(context, table.concat(stderr, "\n")))
  end
end

---@class utils.system_list.Opt
---@field cwd string Working directory of the job.
---@field silent boolean Supress log output.
---@field fail_on_empty boolean Return code 1 if stdout is empty and code is 0.
---@field retry_on_empty integer Number of times to retry job if stdout is empty and code is 0. Implies `fail_on_empty`.
---@field context string Context for the logger.
---@field debug_opt LogJobSpec

---Get the output of a system command.
---@param cmd string[]
---@param cwd_or_opt? string|utils.system_list.Opt
---@return string[] stdout
---@return integer code
---@return string[] stderr
---@overload fun(cmd: string[], cwd: string?)
---@overload fun(cmd: string[], opt: utils.system_list.Opt?)
function M.system_list(cmd, cwd_or_opt)
  if vim.in_fast_event() then
    async.util.scheduler()
  end

  ---@type utils.system_list.Opt
  local opt
  if type(cwd_or_opt) == "string" then
    opt = { cwd = cwd_or_opt }
  else
    opt = cwd_or_opt or {}
  end

  opt.fail_on_empty = vim.F.if_nil(opt.fail_on_empty, (opt.retry_on_empty or 0) > 0)
  opt.context = opt.context or "system_list()"
  local context = ("[%s] "):format(opt.context)
  local logger = require("diffview.logger")
  logger = opt.silent and logger.mock or logger

  local command = table.remove(cmd, 1)
  local num_retries = 0
  local max_retries = opt.retry_on_empty or 0
  local job, stdout, stderr, code, empty
  local job_spec = {
    command = command,
    args = cmd,
    cwd = opt.cwd,
    on_stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }

  for i = 0, max_retries do
    if i > 0 then
      logger.warn(
        ("%sJob expected output, but returned nothing! Retrying %d more time(s)...")
        :format(context, max_retries - i + 1)
      )
      logger.log_job(job, { func = logger.warn, context = opt.context })
      num_retries = num_retries + 1
    end

    stderr = {}
    job = Job:new(job_spec)
    stdout, code = job:sync()
    empty = not (stdout[2] ~= nil or stdout[1] and stdout[1] ~= "")

    if (code ~= 0 or not empty) then
      break
    end
  end

  if opt.debug_opt then
    M.handle_job(job, { fail_on_empty = opt.fail_on_empty, debug_opt = opt.debug_opt })
  elseif not opt.silent then
    M.handle_job(job, { fail_on_empty = opt.fail_on_empty, context = opt.context })
  end

  if num_retries > 0 and code == 0 and not empty then
    logger.info(("%sRetry was successful!"):format(context))
  end

  if opt.fail_on_empty and code == 0 and empty then
    code = 1
  end

  return stdout, code, stderr
end

---Map of options that accept comma separated, list-like values, but don't work
---correctly with Option:set(), Option:append(), Option:prepend(), and
---Option:remove() (seemingly for legacy reasons).
---WARN: This map is incomplete!
local list_like_options = {
  winhighlight = true,
  listchars = true,
  fillchars = true,
}

---@class utils.set_local.Opt
---@field method '"set"'|'"remove"'|'"append"'|'"prepend"' Assignment method. (default: "set")

---@class utils.set_local.ListSpec : string[]
---@field opt utils.set_local.Opt

---@alias WindowOptions table<string, boolean|integer|string|utils.set_local.ListSpec>

---@param winids number[]|number Either a list of winids, or a single winid (0 for current window).
---@param option_map WindowOptions
---@param opt? utils.set_local.Opt
function M.set_local(winids, option_map, opt)
  if type(winids) ~= "table" then
    winids = { winids }
  end

  opt = vim.tbl_extend("keep", opt or {}, { method = "set" }) --[[@as table ]]

  for _, id in ipairs(winids) do
    api.nvim_win_call(id, function()
      for option, value in pairs(option_map) do
        local o = opt
        local fullname = api.nvim_get_option_info(option).name
        local is_list_like = list_like_options[fullname]
        local cur_value = vim.o[fullname]

        if type(value) == "table" then
          if value.opt then
            o = vim.tbl_extend("force", opt, value.opt) --[[@as table ]]
          end

          if is_list_like then
            value = table.concat(value, ",")
          end
        end

        if o.method == "set" then
          vim.opt_local[option] = value

        else
          if o.method == "remove" then
            if is_list_like then
              vim.opt_local[fullname] = cur_value:gsub(",?" .. vim.pesc(value), "")
            else
              vim.opt_local[fullname]:remove(value)
            end

          elseif o.method == "append" then
            if is_list_like then
              vim.opt_local[fullname] = ("%s%s"):format(cur_value ~= "" and cur_value .. ",", value)
            else
              vim.opt_local[fullname]:append(value)
            end

          elseif o.method == "prepend" then
            if is_list_like then
              vim.opt_local[fullname] = ("%s%s%s"):format(
                value,
                cur_value ~= "" and "," or "",
                cur_value
              )
            else
              vim.opt_local[fullname]:prepend(value)
            end
          end
        end
      end
    end)
  end
end

---@param winids number[]|number Either a list of winids, or a single winid (0 for current window).
---@param option string
function M.unset_local(winids, option)
  if type(winids) ~= "table" then
    winids = { winids }
  end

  for _, id in ipairs(winids) do
    api.nvim_win_call(id, function()
      vim.opt_local[option] = nil
    end)
  end
end

---Get a list of all non-floating windows in a given tabpage.
---@param tabid integer
---@return integer[]
function M.tabpage_list_normal_wins(tabid)
  return vim.tbl_filter(function(v)
    return api.nvim_win_get_config(v).relative == ""
  end, api.nvim_tabpage_list_wins(tabid))
end

function M.tabnr_to_id(tabnr)
  for _, id in ipairs(api.nvim_list_tabpages()) do
    if api.nvim_tabpage_get_number(id) == tabnr then
      return id
    end
  end
end

---@generic T
---@param t `T`
---@return T
function M.tbl_clone(t)
  local clone = {}

  for k, v in pairs(t) do
    clone[k] = v
  end

  return clone
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

function M.tbl_pack(...)
  return { n = select("#", ...), ... }
end

function M.tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or #t)
end

function M.tbl_clear(t)
  for k, _ in pairs(t) do
    t[k] = nil
  end
end

---Try property access.
---@param t table
---@param table_path string|string[] Either a `.` separated string of table keys, or a list.
---@return any?
function M.tbl_access(t, table_path)
  local keys = type(table_path) == "table"
      and table_path
      or vim.split(table_path, ".", { plain = true })

  local cur = t

  for _, k in ipairs(keys) do
    cur = cur[k]
    if not cur then
      return nil
    end
  end

  return cur
end

---Perform a map and also filter out index values that would become `nil`.
---@param t table
---@param func fun(value: any): any?
---@return table
function M.tbl_fmap(t, func)
  local ret = {}

  for key, item in pairs(t) do
    local v = func(item)
    if v ~= nil then
      if type(key) == "number" then
        table.insert(ret, v)
      else
        ret[key] = v
      end
    end
  end

  return ret
end

---Create a shallow copy of a portion of a vector. Negative numbers indexes
---from the end.
---@param t vector
---@param first? integer First index, inclusive. (default: 1)
---@param last? integer Last index, inclusive. (default: `#t`)
---@return vector
function M.vec_slice(t, first, last)
  local slice = {}

  if first and first < 0 then
    first = #t + first + 1
  end

  if last and last < 0 then
    last = #t + last + 1
  end

  for i = first or 1, last or #t do
    table.insert(slice, t[i])
  end

  return slice
end

---Return all elements in `t` between `first` and `last`. Negative numbers
---indexes from the end.
---@param t vector
---@param first integer First index, inclusive
---@param last? integer Last index, inclusive
---@return any ...
function M.vec_select(t, first, last)
  return unpack(M.vec_slice(t, first, last))
end

---Join multiple vectors into one.
---@param ... any
---@return vector
function M.vec_join(...)
  local result = {}
  local args = { ... }
  local n = 0

  for i = 1, select("#", ...) do
    if type(args[i]) ~= "nil" then
      if type(args[i]) ~= "table" then
        result[n + 1] = args[i]
        n = n + 1
      else
        for j, v in ipairs(args[i]) do
          result[n + j] = v
        end
        n = n + #args[i]
      end
    end
  end

  return result
end

---Get the result of the union of the given vectors.
---@param ... vector
---@return vector
function M.vec_union(...)
  local result = {}
  local args = {...}
  local seen = {}

  for i = 1, select("#", ...) do
    if type(args[i]) ~= "nil" then
      if type(args[i]) ~= "table" and not seen[args[i]] then
        seen[args[i]] = true
        result[#result+1] = args[i]
      else
        for _, v in ipairs(args[i]) do
          if not seen[v] then
            seen[v] = true
            result[#result+1] = v
          end
        end
      end
    end
  end

  return result
end

---Get the result of the difference of the given vectors.
---@param ... vector
---@return vector
function M.vec_diff(...)
  local args = {...}
  local seen = {}

  for i = 1, select("#", ...) do
    if type(args[i]) ~= "nil" then
      if type(args[i]) ~= "table" then
        if i == 1  then
          seen[args[i]] = true
        elseif seen[args[i]] then
          seen[args[i]] = nil
        end
      else
        for _, v in ipairs(args[i]) do
          if i == 1 then
            seen[v] = true
          elseif seen[v] then
            seen[v] = nil
          end
        end
      end
    end
  end

  return vim.tbl_keys(seen)
end

---Get the result of the symmetric difference of the given vectors.
---@param ... vector
---@return vector
function M.vec_symdiff(...)
  local result = {}
  local args = {...}
  local seen = {}

  for i = 1, select("#", ...) do
    if type(args[i]) ~= "nil" then
      if type(args[i]) ~= "table" then
        seen[args[i]] = seen[args[i]] == 1 and 0 or 1
      else
        for _, v in ipairs(args[i]) do
          seen[v] = seen[v] == 1 and 0 or 1
        end
      end
    end
  end

  for v, state in pairs(seen) do
    if state == 1 then
      result[#result+1] = v
    end
  end

  return result
end

---Return the first index a given object can be found in a vector, or -1 if
---it's not present.
---@param t vector
---@param v any
---@return integer
function M.vec_indexof(t, v)
  for i, vt in ipairs(t) do
    if vt == v then
      return i
    end
  end
  return -1
end

---Append any number of objects to the end of a vector. Pushing `nil`
---effectively does nothing.
---@param t vector
---@param ... any
---@return vector t
function M.vec_push(t, ...)
  local args = {...}

  for i = 1, select("#", ...) do
    t[#t + 1] = args[i]
  end

  return t
end

---Remove an object from a vector.
---@param t vector
---@param v any
---@return boolean success True if the object was removed.
function M.vec_remove(t, v)
  local idx = M.vec_indexof(t, v)

  if idx > -1 then
    table.remove(t, idx)

    return true
  end

  return false
end

---@class ListBufsSpec
---@field loaded boolean Filter out buffers that aren't loaded.
---@field listed boolean Filter out buffers that aren't listed.
---@field no_hidden boolean Filter out buffers that are hidden.
---@field tabpage integer Filter out buffers that are not displayed in a given tabpage.

---@param opt? ListBufsSpec
---@return integer[]
function M.list_bufs(opt)
  opt = opt or {}
  local bufs

  if opt.no_hidden or opt.tabpage then
    local wins = opt.tabpage and api.nvim_tabpage_list_wins(opt.tabpage) or api.nvim_list_wins()
    local bufnr
    local seen = {}
    bufs = {}
    for _, winid in ipairs(wins) do
      bufnr = api.nvim_win_get_buf(winid)
      if not seen[bufnr] then
        bufs[#bufs+1] = bufnr
      end
      seen[bufnr] = true
    end
  else
    bufs = api.nvim_list_bufs()
  end

  return vim.tbl_filter(function(v)
    if opt.loaded and not api.nvim_buf_is_loaded(v) then
      return false
    end
    if opt.listed and not vim.bo[v].buflisted then
      return false
    end
    return true
  end, bufs) --[[@as integer[] ]]
end

---@param name string
---@param opt? ListBufsSpec
function M.find_named_buffer(name, opt)
  for _, v in ipairs(M.list_bufs(opt)) do
    if vim.fn.bufname(v) == name then
      return v
    end
  end
  return nil
end

---@param name string
---@param opt? ListBufsSpec
function M.wipe_named_buffer(name, opt)
  local bn = M.find_named_buffer(name, opt)
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

---Delete a buffer while also preserving the window layout. Changes the current
---buffer to the alt buffer if available, and then deletes it.
---@param force boolean Ignore unsaved changes.
---@param bn? integer
---@return boolean ok, string? err
function M.remove_buffer(force, bn)
  bn = bn or api.nvim_get_current_buf()
  if not force then
    local modified = vim.bo[bn].modified
    if modified then
      return false, "No write since last change!"
    end
  end

  local win_ids = vim.fn.win_findbuf(bn)
  local listed = M.list_bufs({ listed = true })
  for _, id in ipairs(win_ids) do
    if vim.fn.win_gettype(id) ~= "autocmd" then
      api.nvim_win_call(id, function()
        local alt_bufid = vim.fn.bufnr("#")
        if alt_bufid ~= -1 then
          api.nvim_set_current_buf(alt_bufid)
        else
          if #listed > (vim.bo[0].buflisted and 1 or 0) then
            vim.cmd("silent! bp")
          else
            vim.cmd("enew")
          end
        end
      end)
    end
  end

  if api.nvim_buf_is_valid(bn) then
    api.nvim_buf_delete(bn, { force = true })
  end

  return true
end

---@param path string
---@param opt? ListBufsSpec
function M.find_file_buffer(path, opt)
  local p = M.path:absolute(path)
  for _, id in ipairs(M.list_bufs(opt)) do
    if p == vim.api.nvim_buf_get_name(id) then
      return id
    end
  end
end

---Get a list of all windows that contain the given buffer.
---@param bufid integer
---@param tabpage? integer Only search windows in the given tabpage.
---@return integer[]
function M.win_find_buf(bufid, tabpage)
  local result = {}
  local wins

  if tabpage then
    wins = api.nvim_tabpage_list_wins(tabpage)
  else
    wins = api.nvim_list_wins()
  end

  for _, id in ipairs(wins) do
    if api.nvim_win_get_buf(id) == bufid then
      table.insert(result, id)
    end
  end

  return result
end

---Set the (1,0)-indexed cursor position without having to worry about
---out-of-bounds coordinates. The line number is clamped to the number of lines
---in the target buffer.
---@param winid integer
---@param line? integer
---@param column? integer
function M.set_cursor(winid, line, column)
  local bufnr = api.nvim_win_get_buf(winid)

  pcall(api.nvim_win_set_cursor, winid, {
    M.clamp(line or 1, 1, api.nvim_buf_line_count(bufnr)),
    math.max(0, column or 0)
  })
end

---Create a new table with only keys that are valid when passed to
---`nvim_open_win()`.
---@param config table
---@param strict? boolean Raise errors if the given config contains illegal keys.
---@return table
function M.sanitize_float_config(config, strict)
  local mask = {
    relative = true,
    win = true,
    anchor = true,
    width = true,
    height = true,
    bufpos = true,
    row = true,
    col = true,
    focusable = true,
    external = true,
    zindex = true,
    style = true,
    border = true,
    noautocmd = true,
  }
  local result = {}

  for key, value in pairs(config) do
    if mask[key] then
      result[key] = vim.deepcopy(value)
    elseif strict then
      error(("Window config contained invalid key '%s'!"):format(key))
    end
  end

  return result
end

function M.clear_prompt()
  vim.api.nvim_echo({ { "" } }, false, {})
  vim.cmd("redraw")
end

---@class InputCharSpec
---@field clear_prompt boolean (default: true)
---@field allow_non_ascii boolean (default: true)
---@field prompt_hl string (default: nil)

---@param prompt string
---@param opt InputCharSpec
---@return string? Char
---@return string Raw
function M.input_char(prompt, opt)
  opt = vim.tbl_extend("keep", opt or {}, {
    clear_prompt = true,
    allow_non_ascii = false,
    prompt_hl = nil,
  }) --[[@as InputCharSpec ]]

  if prompt then
    vim.api.nvim_echo({ { prompt, opt.prompt_hl } }, false, {})
  end

  local c
  if not opt.allow_non_ascii then
    while type(c) ~= "number" do
      c = vim.fn.getchar()
    end
  else
    c = vim.fn.getchar()
  end

  if opt.clear_prompt then
    M.clear_prompt()
  end

  local s = type(c) == "number" and vim.fn.nr2char(c) or nil
  ---@type string
  local raw = type(c) == "number" and s or c

  return s, raw
end

---@class InputSpec
---@field default string
---@field completion string|function
---@field cancelreturn string
---@field callback fun(response: string?)

---@param prompt string
---@param opt InputSpec
function M.input(prompt, opt)
  local completion = opt.completion
  if type(completion) == "function" then
    DiffviewGlobal.state.current_completer = completion
    completion = "customlist,Diffview__ui_input_completion"
  end

  vim.ui.input({
    prompt = prompt,
    default = opt.default,
    completion = completion,
    cancelreturn = opt.cancelreturn or "__INPUT_CANCELLED__",
  }, opt.callback)
  M.clear_prompt()
end

function M.raw_key(vim_key)
  return api.nvim_eval(string.format([["\%s"]], vim_key))
end

function M.pause(msg)
  vim.cmd("redraw")
  M.input_char(
    "-- PRESS ANY KEY TO CONTINUE -- " .. (msg or ""),
    { allow_non_ascii = true, prompt_hl = "Directory" }
  )
end

---Open a temporary 1x1 floating window.
---@param bufnr? integer Buffer to display.
---@param enter? boolean Enter the window.
---@return integer winid The window handle, or 0 on error.
function M.temp_win(bufnr, enter)
  return api.nvim_open_win(bufnr or 0, not not enter, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 1,
    height = 2, -- Note: Needs to be >=2 in case of winbar (See #193).
    noautocmd = true,
  })
end

---@param func function
---@param ... any
---@return function
function M.wrap_call(func, ...)
  local args = M.tbl_pack(...)

  return function()
    func(M.tbl_unpack(args))
  end
end

local function merge(t, first, mid, last, comparator)
  local n1 = mid - first + 1
  local n2 = last - mid
  local ls = M.vec_slice(t, first, mid)
  local rs = M.vec_slice(t, mid + 1, last)
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
