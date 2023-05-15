local ffi = require("ffi")

local C = ffi.C

local M = setmetatable({}, { __index = ffi })

local HAS_NVIM_0_9 = vim.fn.has("nvim-0.9") == 1

---Check if the |textlock| is active.
---@return boolean
function M.nvim_is_textlocked()
  return C.textlock > 0
end

---Check if the nvim API is locked for any reason.
---See: |api-fast|, |textlock|
---@return boolean
function M.nvim_is_locked()
  if vim.in_fast_event() then return true end

  if HAS_NVIM_0_9 then
    return C.textlock > 0 or C.allbuf_lock > 0 or C.expr_map_lock > 0
  end

  return C.textlock > 0 or C.allbuf_lock > 0 or C.ex_normal_lock > 0
end

ffi.cdef([[
  /// Non-zero when changing text and jumping to another window or editing another buffer is not
  /// allowed.
  extern int textlock;

  /// Non-zero when no buffer name can be changed, no buffer can be deleted and
  /// current directory can't be changed. Used for SwapExists et al.
  extern int allbuf_lock;
]])

if HAS_NVIM_0_9 then
  ffi.cdef([[
    /// Running expr mapping, prevent use of ex_normal() and text changes
    extern int expr_map_lock;
  ]])
else
  ffi.cdef([[
    /// prevent use of ex_normal()
    extern int ex_normal_lock;
  ]])
end

return M
