local fmt = string.format

local lazy = {}

---@class LazyModule : { [string] : unknown }
---@field __get fun(): unknown Load the module if needed, and return it.
---@field __loaded boolean Indicates that the module has been loaded.

---Create a table the triggers a given handler every time it's accessed or
---called, until the handler returns a table. Once the handler has returned a
---table, any subsequent accessing of the wrapper will instead access the table
---returned from the handler.
---@param t any
---@param handler fun(t: any): table?
---@return LazyModule
function lazy.wrap(t, handler)
  local export

  local ret = {
    __get = function()
      if export == nil then
        ---@cast handler function
        export = handler(t)
      end

      return export
    end,
    __loaded = function()
      return export ~= nil
    end,
  }

  return setmetatable(ret, {
    __index = function(_, key)
      if export == nil then ret.__get() end
      ---@cast export table
      return export[key]
    end,
    __newindex = function(_, key, value)
      if export == nil then ret.__get() end
      export[key] = value
    end,
    __call = function(_, ...)
      if export == nil then ret.__get() end
      ---@cast export table
      return export(...)
    end,
  })
end

---Will only require the module after first either indexing, or calling it.
---
---You can pass a handler function to process the module in some way before
---returning it. This is useful i.e. if you're trying to require the result of
---an exported function.
---
---Example:
---
---```lua
--- local foo = require("bar")
--- local foo = lazy.require("bar")
---
--- local foo = require("bar").baz({ qux = true })
--- local foo = lazy.require("bar", function(module)
---    return module.baz({ qux = true })
--- end)
---```
---@param require_path string
---@param handler? fun(module: any): any
---@return LazyModule
function lazy.require(require_path, handler)
  local use_handler = type(handler) == "function"

  return lazy.wrap(require_path, function(s)
    if use_handler then
      ---@cast handler function
      return handler(require(s))
    end
    return require(s)
  end)
end

---Lazily access a table value. If `x` is a string, it's treated as a lazy
---require.
---
---Example:
---
---```lua
--- -- table:
--- local foo = bar.baz.qux.quux
--- local foo = lazy.access(bar, "baz.qux.quux")
--- local foo = lazy.access(bar, { "baz", "qux", "quux" })
---
--- -- require:
--- local foo = require("bar").baz.qux.quux
--- local foo = lazy.access("bar", "baz.qux.quux")
--- local foo = lazy.access("bar", { "baz", "qux", "quux" })
---```
---@param x table|string Either the table to be accessed, or a module require path.
---@param access_path string|string[] Either a `.` separated string of table keys, or a list.
---@return LazyModule
function lazy.access(x, access_path)
  local keys = type(access_path) == "table"
      and access_path
      or vim.split(access_path --[[@as string ]], ".", { plain = true })

  local handler = function(module)
    local export = module

    for _, key in ipairs(keys) do
      export = export[key]
      assert(export ~= nil, fmt("Failed to lazy-access! No key '%s' in table!", key))
    end

    return export
  end

  if type(x) == "string" then
    return lazy.require(x, handler)
  else
    return lazy.wrap(x, handler)
  end
end

return lazy
