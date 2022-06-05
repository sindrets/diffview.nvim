local utils = require "diffview.utils"
local M = {}

---@class ManagedFunc
---@field close fun() Release timer handle.

---@return ManagedFunc
local function wrap(timer, fn)
  local function close()
    timer:stop()
    timer:close()
  end

  return setmetatable({}, {
    __call = function(_, ...)
      fn(...)
    end,
    __index = function(self, k)
      if k == "close" then
        return close
      end
      return self[k]
    end,
  })
end

---Debounces a function on the leading edge.
---@param ms integer Timeout in ms
---@param fn function Function to debounce
---@returns ManagedFunc Debounced function.
function M.debounce_leading(ms, fn)
  local timer = vim.loop.new_timer()
  local running = false
  return wrap(timer, function(...)
    timer:start(ms, 0, function()
      timer:stop()
      running = false
    end)
    if not running then
      running = true
      fn(...)
    end
  end)
end

---Debounces a function on the trailing edge.
---@param ms integer Timeout in ms
---@param fn function Function to debounce
---@returns ManagedFunc Debounced function.
function M.debounce_trailing(ms, fn)
  local timer = vim.loop.new_timer()
  return wrap(timer, function(...)
    local args = utils.tbl_pack(...)
    timer:start(ms, 0, function()
      timer:stop()
      fn(utils.tbl_unpack(args))
    end)
  end)
end

---Throttles a function on the leading edge.
---@param ms integer Timeout in ms
---@param fn function Function to throttle
---@returns ManagedFunc throttled function.
function M.throttle_leading(ms, fn)
  local timer = vim.loop.new_timer()
  local running = false
  return wrap(timer, function(...)
    if not running then
      timer:start(ms, 0, function()
        running = false
        timer:stop()
      end)
      running = true
      fn(...)
    end
  end)
end

---Throttles a function on the trailing edge.
---@param ms integer Timeout in ms
---@param fn function Function to throttle
---@returns ManagedFunc throttled function.
function M.throttle_trailing(ms, fn)
  local timer = vim.loop.new_timer()
  local running = false
  local args
  return wrap(timer, function(...)
    args = utils.tbl_pack(...)
    if not running then
      timer:start(ms, 0, function()
        running = false
        timer:stop()
        fn(utils.tbl_unpack(args))
      end)
      running = true
    end
  end)
end

return M
