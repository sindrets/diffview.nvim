local lazy = {}

---@class LazyModule
---@field __get fun(): any Load the module if needed, and return it.

---Will only require the module after first either indexing, or calling it.
---
---You can pass a handler function to process the module in some way before
---returning it. This is useful i.e. if you're trying to require the result of
---an exported function.
---
---Example:
---
---```
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
  local export

  local t = {
    __get = function()
      if export then
        return export
      end

      if use_handler then
        ---@cast handler function
        export = handler(require(require_path))
      else
        export = require(require_path)
      end
      return export
    end,
  }

  return setmetatable(t, {
    __index = function(_, key)
      if not export then
        t.__get()
      end
      return export[key]
    end,
    __newindex = function(_, key, value)
      if not export then
        t.__get()
      end
      export[key] = value
    end,
    __call = function(_, ...)
      if not export then
        t.__get()
      end
      export(...)
    end,
  })
end

---Lazily access a table value. The `access_path` is a `.` separated string of
---table keys.
---
---Example:
---
---```
--- local foo = require("bar").baz.qux.quux
--- local foo = lazy.access("bar", "baz.qux.quux")
---```
---@param require_path string
---@param access_path string
---@return LazyModule
function lazy.access(require_path, access_path)
  local keys = vim.split(access_path, ".", { plain = true })
  return lazy.require(require_path, function(module)
    local export = module
    for _, key in ipairs(keys) do
      export = export[key]
    end
    return export
  end)
end

return lazy
