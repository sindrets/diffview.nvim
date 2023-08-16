local ffi = require("diffview.ffi")
local oop = require("diffview.oop")

local fmt = string.format
local uv = vim.loop

local DEFAULT_ERROR = "Unkown error."

local M = {}

---@package
---@type { [Future]: boolean }
M._watching = setmetatable({}, { __mode = "k" })

---@package
---@type { [thread]: Future }
M._handles = {}

---@alias AsyncFunc (fun(...): Future)
---@alias AsyncKind "callback"|"void"

local function dstring(object)
  if not DiffviewGlobal.logger then return "" end
  dstring = DiffviewGlobal.logger.dstring
  return dstring(object)
end

---@param ... any
---@return table
local function tbl_pack(...)
  return { n = select("#", ...), ... }
end

---@param t table
---@param i? integer
---@param j? integer
---@return any ...
local function tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or table.maxn(t))
end

---Returns the current thread or `nil` if it's the main thread.
---
---NOTE: coroutine.running() was changed between Lua 5.1 and 5.2:
---  • 5.1: Returns the running coroutine, or `nil` when called by the main
---  thread.
---  • 5.2: Returns the running coroutine plus a boolean, true when the running
---  coroutine is the main one.
---
---For LuaJIT, 5.2 behaviour is enabled with LUAJIT_ENABLE_LUA52COMPAT
---
---We need to handle both.
---
---Source: https://github.com/lewis6991/async.nvim/blob/bad4edbb2917324cd11662dc0209ce53f6c8bc23/lua/async.lua#L10
---@return thread?
local function current_thread()
  local current, ismain = coroutine.running()

  if type(ismain) == "boolean" then
    return not ismain and current or nil
  else
    return current
  end
end

---@class Waitable : diffview.Object
local Waitable = oop.create_class("Waitable")
M.Waitable = Waitable

---@abstract
---@return any ... # Any values returned by the waitable
function Waitable:await() oop.abstract_stub() end

---Schedule a callback to be invoked when this waitable has settled.
---@param callback function
function Waitable:finally(callback)
  (M.void(function()
    local ret = tbl_pack(M.await(self))
    callback(tbl_unpack(ret))
  end))()
end

---@class Future : Waitable
---@operator call : Future
---@field package thread thread
---@field package listeners Future[]
---@field package parent? Future
---@field package func? function
---@field package return_values? any[]
---@field package err? string
---@field package kind AsyncKind
---@field package started boolean
---@field package awaiting_cb boolean
---@field package done boolean
---@field package has_raised boolean # `true` if this future has raised an error.
local Future = oop.create_class("Future", Waitable)

function Future:init(opt)
  opt = opt or {}

  if opt.thread then
    self.thread = opt.thread
  elseif opt.func then
    self.thread = coroutine.create(opt.func)
  else
    error("Either 'thread' or 'func' must be specified!")
  end

  M._handles[self.thread] = self
  self.listeners = {}
  self.kind = opt.kind
  self.started = false
  self.awaiting_cb = false
  self.done = false
  self.has_raised = false
end

---@package
---@return string
function Future:__tostring()
  return dstring(self.thread)
end

---@package
function Future:destroy()
  M._handles[self.thread] = nil
end

---@package
---@param value boolean
function Future:set_done(value)
  self.done = value
  if self:is_watching() then
    self:dprint("done was set:", self.done)
  end
end

---@return boolean
function Future:is_done()
  return not not self.done
end

---@return any ... # If the future has completed, this returns any returned values.
function Future:get_returned()
  if not self.return_values then return end
  return unpack(self.return_values, 2, table.maxn(self.return_values))
end

---@package
---@param ... any
function Future:dprint(...)
  if not DiffviewGlobal.logger then return end
  if DiffviewGlobal.debug_level >= 10 or M._watching[self] then
    local t = { self, "::", ... }
    for i = 1, table.maxn(t) do t[i] = dstring(t[i]) end
    DiffviewGlobal.logger:debug(table.concat(t, " "))
  end
end

---@package
---@param ... any
function Future:dprintf(...)
  self:dprint(fmt(...))
end

---Start logging debug info about this future.
function Future:watch()
  M._watching[self] = true
end

---Stop logging debug info about this future.
function Future:unwatch()
  M._watching[self] = nil
end

---@package
---@return boolean
function Future:is_watching()
  return not not M._watching[self]
end

---@package
---@param force? boolean
function Future:raise(force)
  if self.has_raised and not force then return end
  self.has_raised = true
  error(self.err)
end

---@package
function Future:step(...)
  self:dprint("step")
  local ret = { coroutine.resume(self.thread, ...) }
  local ok = ret[1]

  if not ok then
    local err = ret[2] or DEFAULT_ERROR
    local func_info

    if self.func then
      func_info = debug.getinfo(self.func, "uS")
    end

    local msg = fmt(
      "The coroutine failed with this message: \n"
        .. "\tcontext: cur_thread=%s co_thread=%s %s\n%s",
      dstring(current_thread() or "main"),
      dstring(self.thread),
      func_info and fmt("co_func=%s:%d", func_info.short_src, func_info.linedefined) or "",
      debug.traceback(self.thread, err)
    )
    self:set_done(true)
    self:notify_all(false, msg)
    self:destroy()
    self:raise()
    return
  end

  if coroutine.status(self.thread) == "dead" then
    self:dprint("handle dead")
    self:set_done(true)
    self:notify_all(true, unpack(ret, 2, table.maxn(ret)))
    self:destroy()
    return
  end
end

---@package
---@param ok boolean
---@param ... any
function Future:notify_all(ok, ...)
  local ret_values = tbl_pack(ok, ...)

  if not ok then
    self.err = ret_values[2] or DEFAULT_ERROR
  end

  local seen = {}

  while next(self.listeners) do
    local handle = table.remove(self.listeners, #self.listeners) --[[@as Future ]]

    -- We don't want to trigger multiple steps for a single thread
    if handle and not seen[handle.thread] then
      self:dprint("notifying:", handle)
      seen[handle.thread] = true
      handle:step(ret_values)
    end
  end
end

---@override
---@return any ... # Return values
function Future:await()
  if self.err then
    self:raise(true)
    return
  end

  if self:is_done() then
    return self:get_returned()
  end

  local current = current_thread()

  if not current then
    -- Await called from main thread
    return self:toplevel_await()
  end

  local parent_handle = M._handles[current]

  if not parent_handle then
    -- We're on a thread not managed by us: create a Future wrap around the
    -- thread
    self:dprint("creating a wrapper around unmanaged thread")
    self.parent = Future({
      thread = current,
      kind = "void",
    })
  else
    self.parent = parent_handle
  end

  if current ~= self.thread then
    -- We want the current thread to be notified when this future is done /
    -- terminated
    table.insert(self.listeners, self.parent)
  end

  self:dprintf("awaiting: yielding=%s listeners=%s", dstring(current), dstring(self.listeners))
  coroutine.yield()

  local ok

  if not self.return_values then
    ok = self.err == nil
  else
    ok = self.return_values[1]

    if not ok then
      self.err = self.return_values[2] or DEFAULT_ERROR
    end
  end

  if not ok then
    self:raise(true)
    return
  end

  return self:get_returned()
end

---@package
---@return any ...
function Future:toplevel_await()
  local ok, status

  while true do
    ok, status = vim.wait(1000 * 60, function()
      return coroutine.status(self.thread) == "dead"
    end, 1)

    -- Respect interrupts
    if status ~= -1 then break end
  end

  if not ok then
    if status == -1 then
      error("Async task timed out!")
    elseif status == -2 then
      error("Async task got interrupted!")
    end
  end

  if self.err then
    self:raise(true)
    return
  end

  return self:get_returned()
end

---@class async._run.Opt
---@field kind AsyncKind
---@field nparams? integer
---@field args any[]

---@package
---@param func function
---@param opt async._run.Opt
function M._run(func, opt)
  opt = opt or {}

  local handle ---@type Future
  local use_err_handler = not not current_thread()

  local function wrapped_func(...)
    if use_err_handler then
      -- We are not on the main thread: use custom err handler
      local ok = xpcall(func, function(err)
        handle.err = debug.traceback(err, 2)
      end, ...)

      if not ok then
        handle:dprint("an error was raised: terminating")
        handle:set_done(true)
        handle:destroy()
        error(handle.err, 0)
        return
      end
    else
      func(...)
    end

    -- Check if we need to yield until cb. We might not need to if the cb was
    -- called in a synchronous way.
    if opt.kind == "callback" and not handle:is_done() then
      handle.awaiting_cb = true
      handle:dprintf("yielding for cb: current=%s", dstring(current_thread()))
      coroutine.yield()
      handle:dprintf("resuming after cb: current=%s", dstring(current_thread()))
    end

    handle:set_done(true)
  end

  if opt.kind == "callback" then
    local cur_cb = opt.args[opt.nparams]

    local function wrapped_cb(...)
      handle:set_done(true)
      handle.return_values = { true, ... }
      if cur_cb then cur_cb(...) end

      if handle.awaiting_cb then
        -- The thread was yielding for the callback: resume
        handle.awaiting_cb = false
        handle:step()
      end

      handle:notify_all(true, ...)
    end

    opt.args[opt.nparams] = wrapped_cb
  end

  handle = Future({ func = wrapped_func, kind = opt.kind })
  handle:dprint("created thread")
  handle.func = func
  handle.started = true
  handle:step(tbl_unpack(opt.args))

  return handle
end

---Create an async task for a function with no return values.
---@param func function
---@return AsyncFunc
function M.void(func)
  return function(...)
    return M._run(func, {
      kind = "void",
      args = { ... },
    })
  end
end

---Create an async task for a callback style function.
---@param func function
---@param nparams? integer # The number of parameters.
---The last parameter in `func` must be the callback. For Lua functions this
---can be derived through reflection. If `func` is an FFI procedure then
---`nparams` is required.
---@return AsyncFunc
function M.wrap(func, nparams)
  if not nparams then
    local info = debug.getinfo(func, "uS")
    assert(info.what == "Lua", "Parameter count can only be derived for Lua functions!")
    nparams = info.nparams
  end

  return function(...)
    return M._run(func, {
      nparams = nparams,
      kind = "callback",
      args = { ... },
    })
  end
end

---@param waitable Waitable
---@return any ... # Any values returned by the waitable
function M.await(waitable)
  return waitable:await()
end

---Await the async function `x` with the given arguments in protected mode. `x`
---may also be a waitable, in which case the subsequent parameters are ignored.
---@param x AsyncFunc|Waitable # The async function or waitable.
---@param ... any # Arguments to be applied to the `x` if it's a function.
---@return boolean ok # `false` if the execution of `x` failed.
---@return any result # Either the first returned value from `x` or an error message.
---@return any ... # Any subsequent values returned from `x`.
function M.pawait(x, ...)
  local args = tbl_pack(...)
  return pcall(function()
    if type(x) == "function" then
      return M.await(x(tbl_unpack(args)))
    else
      return x:await()
    end
  end)
end

-- ###############################
-- ### VARIOUS ASYNC UTILITIES ###
-- ###############################

local await = M.await

---Create a synchronous version of an async `void` task. Calling the resulting
---function will block until the async task is done.
---@param func function
function M.sync_void(func)
  local afunc = M.void(func)

  return function(...)
    return await(afunc(...))
  end
end

---Create a synchronous version of an async `wrap` task. Calling the resulting
---function will block until the async task is done. Any values that were
---passed to the callback will be returned.
---@param func function
---@param nparams? integer
---@return (fun(...): ...)
function M.sync_wrap(func, nparams)
  local afunc = M.wrap(func, nparams)

  return function(...)
    return await(afunc(...))
  end
end

---Run the given async tasks concurrently, and then wait for them all to
---terminate.
---@param tasks (AsyncFunc|Waitable)[]
M.join = M.void(function(tasks)
  ---@type Waitable[]
  local futures = {}

  -- Ensure all async tasks are started
  for _, cur in ipairs(tasks) do
    if cur then
      if type(cur) == "function" then
        futures[#futures+1] = cur()
      else
        ---@cast cur Waitable
        futures[#futures+1] = cur
      end
    end
  end

  -- Await all futures
  for _, future in ipairs(futures) do
    await(future)
  end
end)

---Run, and await the given async tasks in sequence.
---@param tasks (AsyncFunc|Waitable)[]
M.chain = M.void(function(tasks)
  for _, task in ipairs(tasks) do
    if type(task) == "function" then
      ---@cast task AsyncFunc
      await(task())
    else
      ---@cast task Waitable
      await(task)
    end
  end
end)

---Async task that resolves after the given `timeout` ms passes.
---@param timeout integer # Duration of the timeout (ms)
M.timeout = M.wrap(function(timeout, callback)
  local timer = assert(uv.new_timer())

  timer:start(
    timeout,
    0,
    function()
      if not timer:is_closing() then timer:close() end
      callback()
    end
  )
end)

---Yield until the Neovim API is available.
---@param fast_only? boolean # Only schedule if in an |api-fast| event.
---   When this is `true`, the scheduler will resume immediately unless the
---   editor is in an |api-fast| event. This means that the API might still be
---   limited by other mechanisms (i.e. |textlock|).
M.scheduler = M.wrap(function(fast_only, callback)
  if (fast_only and not vim.in_fast_event()) or not ffi.nvim_is_locked() then
    callback()
    return
  end

  vim.schedule(callback)
end)

M.schedule_now = M.wrap(vim.schedule, 1)

return M
