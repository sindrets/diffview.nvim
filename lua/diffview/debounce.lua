local async = require("diffview.async")
local utils = require("diffview.utils")

local await = async.await
local uv = vim.loop

local M = {}

---@class Closeable
---@field close fun() # Perform cleanup and release the associated handle.

---@class ManagedFn : Closeable
---@operator call : unknown ...

---@param ... uv_handle_t
function M.try_close(...)
  local args = { ... }

  for i = 1, select("#", ...) do
    local handle = args[i]

    if handle and not handle:is_closing() then
      handle:close()
    end
  end
end

---@return ManagedFn
local function wrap(timer, fn)
  return setmetatable({}, {
    __call = function(_, ...)
      fn(...)
    end,
    __index = {
      close = function()
        timer:stop()
        M.try_close(timer)
      end,
    },
  })
end

---Debounces a function on the leading edge.
---@param ms integer Timeout in ms
---@param fn function Function to debounce
---@return ManagedFn # Debounced function.
function M.debounce_leading(ms, fn)
  local timer = assert(uv.new_timer())
  local lock = false

  return wrap(timer, function(...)
    timer:start(ms, 0, function()
      timer:stop()
      lock = false
    end)

    if not lock then
      lock = true
      fn(...)
    end
  end)
end

---Debounces a function on the trailing edge.
---@param ms integer Timeout in ms
---@param rush_first boolean If the managed fn is called and it's not recovering from a debounce: call the fn immediately.
---@param fn function Function to debounce
---@return ManagedFn # Debounced function.
function M.debounce_trailing(ms, rush_first, fn)
  local timer = assert(uv.new_timer())
  local lock = false
  local debounced_fn, args

  debounced_fn = wrap(timer, function(...)
    if not lock and rush_first and args == nil then
      lock = true
      fn(...)
    else
      args = utils.tbl_pack(...)
    end

    timer:start(ms, 0, function()
      lock = false
      timer:stop()
      if args then
        local a = args
        args = nil
        fn(utils.tbl_unpack(a))
      end
    end)
  end)

  return debounced_fn
end

---Throttles a function on the leading edge.
---@param ms integer Timeout in ms
---@param fn function Function to throttle
---@return ManagedFn # throttled function.
function M.throttle_leading(ms, fn)
  local timer = assert(uv.new_timer())
  local lock = false

  return wrap(timer, function(...)
    if not lock then
      timer:start(ms, 0, function()
        lock = false
        timer:stop()
      end)

      lock = true
      fn(...)
    end
  end)
end

---Throttles a function on the trailing edge.
---@param ms integer Timeout in ms
---@param rush_first boolean If the managed fn is called and it's not recovering from a throttle: call the fn immediately.
---@param fn function Function to throttle
---@return ManagedFn # throttled function.
function M.throttle_trailing(ms, rush_first, fn)
  local timer = assert(uv.new_timer())
  local lock = false
  local throttled_fn, args

  throttled_fn = wrap(timer, function(...)
    if lock or (not rush_first and args == nil) then
      args = utils.tbl_pack(...)
    end

    if lock then return end

    lock = true

    if rush_first then
      fn(...)
    end

    timer:start(ms, 0, function()
      lock = false
      if args then
        local a = args
        args = nil
        if rush_first then
          throttled_fn(utils.tbl_unpack(a))
        else
          fn(utils.tbl_unpack(a))
        end
      end
    end)
  end)

  return throttled_fn
end

---Throttle a function against a target framerate. The function will always be
---called when the editor is unlocked and writing to buffers is possible.
---@param framerate integer # Target framerate. Set to <= 0 to render whenever the scheduler is ready.
---@param fn function
function M.throttle_render(framerate, fn)
  local lock = false
  local use_framerate = framerate > 0
  local period = use_framerate and (1000 / framerate) * 1E6 or 0
  local throttled_fn
  local args, last

  throttled_fn = async.void(function(...)
    args = utils.tbl_pack(...)
    if lock then return end

    lock = true
    await(async.schedule_now())
    fn(utils.tbl_unpack(args))
    args = nil

    if use_framerate then
      local now = uv.hrtime()

      if last and now - last < period then
        local wait = period - (now - last)
        await(async.timeout(wait / 1E6))
        last = last + period
      else
        last = now
      end
    end

    lock = false

    if args ~= nil then
      throttled_fn(utils.tbl_unpack(args))
    end
  end)

  return throttled_fn
end

---Repeatedly call `func` with a fixed time delay.
---@param func function
---@param delay integer # Delay between executions (ms)
---@return Closeable
function M.set_interval(func, delay)
  local timer = assert(uv.new_timer())

  local ret = {
    close = function()
      timer:stop()
      M.try_close(timer)
    end,
  }

  timer:start(delay, delay, function()
    local should_close = func()
    if type(should_close) == "boolean" and should_close then
      ret.close()
    end
  end)

  return ret
end

---Call `func` after a fixed time delay.
---@param func function
---@param delay integer # Delay until execution (ms)
---@return Closeable
function M.set_timeout(func, delay)
  local timer = assert(uv.new_timer())

  local ret = {
    close = function()
      timer:stop()
      M.try_close(timer)
    end,
  }

  timer:start(delay, 0, function()
    func()
    ret.close()
  end)

  return ret
end

return M

