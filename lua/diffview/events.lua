local oop = require("diffview.oop")

local M = {}

---@class Event

---@class EEvent
---@field FILES_STAGED Event
local Event = oop.enum({
  "FILES_STAGED",
})

---@class EventEmitter
---@field listeners table<Event, function[]>
local EventEmitter = oop.Object
EventEmitter = oop.create_class("EventEmitter")

---EventEmitter constructor.
---@return EventEmitter
function EventEmitter:init()
  self.listeners = {}
end

function EventEmitter:on(event, callback)
  if not self.listeners[event] then
    self.listeners[event] = {}
  end
  table.insert(self.listeners[event], function(args)
    callback(unpack(args))
  end)
end

function EventEmitter:once(event, callback)
  if not self.listeners[event] then
    self.listeners[event] = {}
  end
  local emitted = false
  table.insert(self.listeners[event], function(args)
    if not emitted then
      emitted = true
      callback(unpack(args))
    end
  end)
end

function EventEmitter:emit(event, ...)
  local args = { ... }
  if type(self.listeners[event]) == "table" then
    for _, cb in ipairs(self.listeners[event]) do
      cb(args)
    end
  end
end

M.Event = Event
M.EventEmitter = EventEmitter
return M
