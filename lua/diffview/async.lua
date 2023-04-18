---@diagnostic disable: invisible
local oop = require("diffview.oop")
local lazy = require("diffview.lazy")

local logger = lazy.require("diffview.logger") ---@module "diffview.logger"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local tbl_pack, tbl_unpack = lazy.access(utils, "tbl_pack"), lazy.access(utils, "tbl_unpack")
local dstring = lazy.access(logger, "dstring")
local dprint = lazy.wrap(logger, function(t)
  return t.lvl(10).debug
end)
local fmt = string.format

local DEFAULT_ERROR = "Unkown error."

local M = {}

---@private
---@type { [Future]: boolean }
M._watching = setmetatable({}, { __mode = "k" })

---@private
---@type { [thread]: Future }
M._handles = {}

---@class AsyncFunc : function
---@operator call : Future

---@alias AsyncKind "callback"|"void"

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

---@abstract
---@return any ... # Any values returned by the waitable
function Waitable:await() oop.abstract_stub() end

M.Waitable = Waitable

---@class Future : Waitable
---@operator call : Future
---@field private thread thread
---@field private listeners Future[]
---@field private parent? Future
---@field private return_values? any[]
---@field private err? string
---@field private kind AsyncKind
---@field private started boolean
---@field private awaiting_cb boolean
---@field private done boolean
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
end

---@private
---@return string
function Future:__tostring()
  return dstring(self.thread)
end

---@private
function Future:destroy()
  M._handles[self.thread] = nil
end

---@private
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

---@private
---@param ... any
function Future:dprint(...)
  if DiffviewGlobal.debug_level >= 10 or M._watching[self] then
    local args = { fmt("%.2f", utils.now()), self, "::", ... }
    local t = {}

    for i = 1, table.maxn(args) do
      t[i] = dstring(args[i])
    end

    logger:debug(table.concat(t, " "))
  end
end

---@private
---@param ... any
function Future:dprintf(...)
  self:dprint(fmt(...))
end

---@private
---Start logging debug info about this future.
function Future:watch()
  M._watching[self] = true
end

---@private
---Stop logging debug info about this future.
function Future:unwatch()
  M._watching[self] = nil
end

---@private
---@return boolean
function Future:is_watching()
  return not not M._watching[self]
end

---@private
function Future:step(...)
  self:dprint("step")
  local ret = { coroutine.resume(self.thread, ...) }
  local ok = ret[1]

  if not ok then
    local err = ret[2] or DEFAULT_ERROR
    local msg = fmt(
      "%s :: The coroutine failed with this message: \n%s",
      dstring(self.thread),
      debug.traceback(self.thread, err)
    )
    self:set_done(true)
    self:notify_all(false, msg)
    self:destroy()
    error(msg)
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

---@private
---@param ok boolean
---@param ... any
function Future:notify_all(ok, ...)
  local ret_values = tbl_pack(ok, ...)

  if not ok then
    self.err = ret_values[2] or DEFAULT_ERROR
  end

  -- self:dprint("notifying listeners:", self.listeners)
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

---@return any ... # Return values
function Future:await()
  if self.err then
    error(self.err)
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

  if self.return_values then
    local ok, err = self.return_values[1], self.return_values[2]

    if not ok then
      self.err = err or DEFAULT_ERROR
      error(self.err)
      return
    end
  end

  return self:get_returned()
end

---@private
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
    error(self.err)
    return
  end

  return self:get_returned()
end

---@class async._run.Opt
---@field kind AsyncKind
---@field nparams? integer
---@field args any[]

---@private
---@param func function
---@param opt async._run.Opt
function M._run(func, opt)
  opt = opt or {}

  local handle ---@type Future
  local wrapped_cb
  local use_err_handler = not not (current_thread())

  local function wrapped_func(...)
    if use_err_handler then
      -- We are not on the main thread: use custom err handler
      local ok = xpcall(func, function(err)
        local msg = debug.traceback(err, 2)
        handle:notify_all(false, msg)
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

    function wrapped_cb(...)
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

--
-- VARIOUS ASYNC UTILITIES
--

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
---@param ... AsyncFunc|Future
M.join = M.void(function(...)
  local args = { ... }
  local futures = {} ---@type Future[]

  -- Ensure all async tasks are started
  for i = 1, select("#", ...) do
    local cur = args[i]

    if cur then
      if type(cur) == "function" then
        futures[#futures+1] = cur()
      else
        ---@cast cur Future
        futures[#futures+1] = cur
      end
    end
  end

  -- Await all futures
  for i, future in ipairs(futures) do
    dprint("waiting", i, future)
    await(future)
    dprint("finished", i, future)
  end
end)

---Run, and await the given async tasks in sequence.
---@param ... AsyncFunc|Future # Async functions or futures
M.chain = M.void(function(...)
  local args = { ... }

  for i = 1, select("#", ...) do
    local cur = args[i]
    if cur then
      if type(cur) == "function" then
        ---@cast cur AsyncFunc
        await(cur())
      else
        ---@cast cur Future
        await(cur)
      end
    end
  end
end)

---Async task that resolves after the given `timeout` ms passes.
---@param timeout integer # Duration of the timeout (ms)
M.timeout = M.wrap(function(timeout, callback)
  local timer = vim.loop.new_timer()
  assert(timer, "Failed to initialize timer!")
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
M.scheduler = M.wrap(vim.schedule, 1)

return M
