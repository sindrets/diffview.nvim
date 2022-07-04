local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

local short_flag_pat = "^%-(%a)=?(.*)"
local long_flag_pat = "^%-%-(%a[%a%d-]*)=?(.*)"

---@class ArgObject : Object
---@field flags table<string, string>
---@field args string[]
---@field post_args string[]
local ArgObject = oop.create_class("ArgObject")

---ArgObject constructor.
---@param flags table<string, string>
---@param args string[]
---@return ArgObject
function ArgObject:init(flags, args, post_args)
  self.flags = flags
  self.args = args
  self.post_args = post_args
end

---@class ArgObject.GetFlagSpec
---@field plain boolean Never cast string values to booleans.
---@field expect_list boolean Return a list of all defined values for the given flag.
---@field expect_string boolean Inferred boolean values are changed to be empty strings.
---@field no_empty boolean Return nil if the value is an empty string. Implies `expect_string`.
---@field expand boolean Expand wildcards and special keywords (`:h expand()`).

---Get a flag value.
---@param names string|string[] Flag synonyms
---@param opt? ArgObject.GetFlagSpec
---@return string|boolean
function ArgObject:get_flag(names, opt)
  opt = opt or {}
  if opt.no_empty then
    opt.expect_string = true
  end

  if type(names) ~= "table" then
    names = { names }
  end

  local values = {}
  for _, name in ipairs(names) do
    if self.flags[name] then
      utils.vec_push(values, unpack(self.flags[name]))
    end
  end

  values = utils.tbl_fmap(values, function(v)
    if opt.expect_string and v == "true" then
      -- Undo inferred boolean values
      if opt.no_empty then
        return nil
      end
      v = ""
    elseif not opt.plain and (v == "true" or v == "false") then
      -- Cast to boolean
      v = v == "true"
    end

    if opt.expand then
      v = vim.fn.expand(v)
    end

    return v
  end)

  -- If a list isn't expcted: return the last defined value for this flag.
  return opt.expect_list and values or values[#values]
end

---@class FlagValueMap : Object
---@field map table<string, string[]>
local FlagValueMap = oop.create_class("FlagValueMap")

---FlagValueMap constructor
---@return FlagValueMap
function FlagValueMap:init()
  self.map = {}
end

---@param flag_synonyms string[]
---@param producer? string[]|fun(name_lead: string, arg_lead: string): string[]
function FlagValueMap:put(flag_synonyms, producer)
  for _, flag in ipairs(flag_synonyms) do
    if flag:sub(1, 1) ~= "-" then
      if #flag > 1 then
        flag = "--" .. flag
      else
        flag = "-" .. flag
      end
    end
    self.map[flag] = producer or { "true", "false" }
    self.map[#self.map+1] = flag
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
  if type(self.map[flag_name]) == "function" then
    local is_short = flag_name:match(short_flag_pat) ~= nil
    return self.map[flag_name](flag_name .. (not is_short and "=" or ""), "")
  end
  return self.map[flag_name]
end

---Get a list of all flag names.
---@return string[]
function FlagValueMap:get_all_names()
  return utils.vec_slice(self.map)
end

---@param arg_lead string
---@return string[]?
function FlagValueMap:get_completion(arg_lead)
  local name
  local is_short = arg_lead:match(short_flag_pat) ~= nil
  if is_short then
    name = arg_lead:sub(1, 2)
    arg_lead = arg_lead:match("..=?(.*)") or ""
  else
    name = arg_lead:gsub("=.*", "")
    arg_lead = arg_lead:match("=(.*)") or ""
  end

  local name_lead = name .. (not is_short and "=" or "")
  local values = self.map[name]
  if type(values) == "function" then
    values = values(name_lead, arg_lead)
  end
  if not values then
    return nil
  end

  local items = {}
  for _, v in ipairs(values) do
    local e_lead, _ = vim.pesc(arg_lead)
    if v:match(e_lead) then
      items[#items+1] = name_lead .. v
    end
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

      if not flags[flag] then
        flags[flag] = {}
      end

      table.insert(flags[flag], value)
      goto continue
    end

    flag, value = arg:match(long_flag_pat)
    if flag then
      value = (value == "") and "true" or value

      if not flags[flag] then
        flags[flag] = {}
      end

      table.insert(flags[flag], value)
      goto continue
    end

    table.insert(pre_args, arg)

    ::continue::
  end

  return ArgObject(flags, pre_args, post_args)
end

---Split the line range from an EX command arg.
---@param arg string
---@return string range, string command
function M.split_ex_range(arg)
  local idx = arg:match(".*()%A")
  if not idx then
    return  "", arg
  end

  local slice = arg:sub(idx or 1)
  idx = slice:match("[^']()%a")

  if idx then
    return  arg:sub(1, (#arg - #slice) + idx - 1), slice:sub(idx)
  end

  return  arg, ""
end

---Scan an EX command string and split it into individual args.
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
  while i <= #cmd_line do
    if not argidx and i > cur_pos then
      argidx = #args + 1
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
        if arg == "--" and i - 1 < #cmd_line then
          divideridx = #args
        end
      end
      arg = ""
      -- Skip whitespace
      i = i + cmd_line:sub(i, -1):match("^%s+()") - 2
    else
      arg = arg .. char
    end

    i = i + 1
  end

  if #arg > 0 then
    table.insert(args, arg)
    if arg == "--" and cmd_line:sub(#cmd_line, #cmd_line) ~= "-" then
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

---Scan a shell-like string and split it into individual args. This scanner
---understands quoted args.
---@param cmd_line string
---@param cur_pos number
---@return string[] args
---@return integer argidx
---@return integer divideridx
function M.scan_sh_args(cmd_line, cur_pos)
  local args = {}
  local divideridx = math.huge
  local argidx
  local cur_quote
  local arg = ""

  local i = 1
  while i <= #cmd_line do
    if not argidx and i > cur_pos then
      argidx = #args + 1
    end

    local char = cmd_line:sub(i, i)
    if char == "\\" then
      if i < #cmd_line then
        i = i + 1
        arg = arg .. cmd_line:sub(i, i)
      end
    elseif cur_quote then
      if char == cur_quote then
        cur_quote = nil
      else
        arg = arg .. char
      end
    elseif char == [[']] or char == [["]] then
      cur_quote = char
    elseif char:match("%s") then
      if arg ~= "" then
        table.insert(args, arg)
        if arg == "--" and i - 1 < #cmd_line then
          divideridx = #args
        end
      end
      arg = ""
      -- Skip whitespace
      i = i + cmd_line:sub(i, -1):match("^%s+()") - 2
    else
      arg = arg .. char
    end

    i = i + 1
  end

  if cur_quote then
    error("The given command line contains a non-terminated string!")
  end

  if #arg > 0 then
    table.insert(args, arg)
    if arg == "--" and cmd_line:sub(#cmd_line, #cmd_line) ~= "-" then
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
  if vim.tbl_contains(truthy, value) then
    return true
  end
  if vim.tbl_contains(falsy, value) then
    return false
  end
  return default
end

M.ArgObject = ArgObject
M.FlagValueMap = FlagValueMap
return M
