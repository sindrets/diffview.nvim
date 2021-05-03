local M = {}

local short_flag_pat = "^%-(%a)=?(.*)"
local long_flag_pat = "^%-%-(%a[%a%d-]*)=?(.*)"

---@class ArgObject
---@field flags table<string, string>
---@field args string[]
---@field post_args string[]
local ArgObject = {}
ArgObject.__index = ArgObject

---ArgObject constructor.
---@param flags table<string, string>
---@param args string[]
---@return ArgObject
function ArgObject:new(flags, args, post_args)
  local this = {
    flags = flags,
    args = args,
    post_args = post_args
  }
  setmetatable(this, self)
  return this
end

---Get a flag value.
---@vararg ... string[] Flag synonyms
---@return any
function ArgObject:get_flag(...)
  for _, name in ipairs({...}) do
    if self.flags[name] ~= nil then return self.flags[name] end
  end
end

---Parse args and create an ArgObject.
---@param args string[]
---@return ArgObject
function M.parse(args)
  local flags = {}
  local pre_args = {}
  local post_args = {}

  for i, arg in ipairs(args) do
    if arg == "--" then
      for j = i + 1, #args do
        table.insert(post_args, args[j])
      end
      break
    end

    local flag, value
    flag, value = arg:match(short_flag_pat)
    if flag then
      value = (value == "") and "true" or value
      flags[flag] = value
      goto continue
    end

    flag, value = arg:match(long_flag_pat)
    if flag then
      value = (value == "") and "true" or value
      flags[flag] = value
      goto continue
    end

    table.insert(pre_args, arg)

    ::continue::
  end

  return ArgObject:new(flags, pre_args, post_args)
end

function M.ambiguous_bool(value, default, truthy, falsy)
  if vim.tbl_contains(truthy, value) then return true end
  if vim.tbl_contains(falsy, value) then return false end
  return default
end

M.ArgObject = ArgObject
return M
