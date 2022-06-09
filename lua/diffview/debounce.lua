local utils = require "diffview.utils"
local M = {}

---@class ManagedFn
---@field close fun() Release timer handle.

---@return ManagedFn
local function wrap(timer, fn)
  local function close()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end

  return setmetatable({}, {
    __call = function(_, ...)
      fn(...)
    end,
    __index = function(_, k)
      if k == "close" then
        return close
      end
      return nil
    end,
  })
end

---Debounces a function on the leading edge.
---@param ms integer Timeout in ms
---@param fn function Function to debounce
---@return ManagedFn # Debounced function.
function M.debounce_leading(ms, fn)
  local timer = vim.loop.new_timer()
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
  local timer = vim.loop.new_timer()
  local lock = false
  local debounced_fn, args

  debounced_fn = wrap(timer, function(...)
    if lock then
      args = utils.tbl_pack(...)
    else
      lock = true
      if rush_first then
        fn(...)
      end
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
  local timer = vim.loop.new_timer()
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
  local timer = vim.loop.new_timer()
  local lock = false
  local throttled_fn, args

  throttled_fn = wrap(timer, function(...)
    if lock then
      args = utils.tbl_pack(...)
      return
    end

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

return M
