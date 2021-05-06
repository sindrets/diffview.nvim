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

---@class FlagValueMap
---@field map table<string, string[]>
local FlagValueMap = {}
FlagValueMap.__index = FlagValueMap

---FlagValueMap constructor
---@return FlagValueMap
function FlagValueMap:new()
  local this = {
    map = {}
  }
  setmetatable(this, self)
  return this
end

function FlagValueMap:put(flag_synonyms, values)
  for _, flag in ipairs(flag_synonyms) do
    if flag:sub(1, 1) ~= "-" then
      if #flag > 1 then
        flag = "--" .. flag
      else
        flag = "-" .. flag
      end
    end
    self.map[flag] = values
  end
end

---Get list of possible values for a given flag.
---@param flag_name string
---@return string[]
function FlagValueMap:get(flag_name)
  if flag_name:sub(1, 1) ~= "-" then
    if #flag_name > 1 then
      flag_name = "--" .. flag_name
    else
      flag_name = "-" .. flag_name
    end
  end
  return self.map[flag_name]
end

---Get a list of all flag names.
---@return string[]
function FlagValueMap:get_all_names()
  local names = {}
  for name, _ in pairs(self.map) do
    table.insert(names, name)
  end
  return names
end

function FlagValueMap:get_completion(flag_name)
  local is_short = flag_name:match(short_flag_pat) ~= nil
  if is_short then
    flag_name = flag_name:sub(1,2)
  else
    flag_name = flag_name:gsub("=.*", "")
  end

  local values = self.map[flag_name]
  if not values then return nil end

  local items = {}
  for _, v in ipairs(values) do
    table.insert(items, flag_name .. (not is_short and "=" or "") .. v)
  end

  return items
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

---Scan an EX arg string and split into individual args.
---@param cmd_line string
---@param cur_pos number
---@return string[] args
---@return integer argidx
---@return integer divideridx
function M.scan_ex_args(cmd_line, cur_pos)
  local args = {}
  local divideridx = math.huge
  local argidx
  local arg = ""

  local i = 1
  while i < #cmd_line do
    if not argidx and i > cur_pos then
      argidx = #args
    end

    local char = cmd_line:sub(i, i)
    if char == "\\" then
      arg = arg .. char
      if i < #cmd_line then
        i = i + 1
        arg = arg .. cmd_line:sub(i, i)
      end
    elseif char:match("%s") then
      if arg ~= "" then
        table.insert(args, arg)
        if arg == "--" then
          divideridx = #args
        end
      end
      arg = ""
      i = i + cmd_line:sub(i, -1):match("^%s+()") - 2
    else
      arg = arg .. char
    end

    i = i + 1
  end

  if #arg > 0 then
    table.insert(args, arg)
    if arg == "--" then
      divideridx = #args
    end
  end

  if not argidx then
    argidx = #args
    if cmd_line:sub(#cmd_line, #cmd_line):match("%s") then
      argidx = argidx + 1
    end
  end

  return args, argidx, divideridx
end

function M.ambiguous_bool(value, default, truthy, falsy)
  if vim.tbl_contains(truthy, value) then return true end
  if vim.tbl_contains(falsy, value) then return false end
  return default
end

M.ArgObject = ArgObject
M.FlagValueMap = FlagValueMap
return M
