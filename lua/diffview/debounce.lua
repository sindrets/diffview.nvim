local utils = require("diffview.utils")

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

