local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

---@class Event

---@class EEvent
---@field FILES_STAGED Event
local Event = oop.enum({
  "FILES_STAGED",
})

---@class EventEmitter : Object
---@field listeners table<Event, function[]>
---@field any_listeners function[]
---@field emit_lock table<Event, boolean>
local EventEmitter = oop.create_class("EventEmitter")

---EventEmitter constructor.
---@return EventEmitter
function EventEmitter:init()
  self.listeners = {}
  self.any_listeners = {}
  self.emit_lock = {}
end

---Subscribe to a given event.
---@param event any Event identifier.
---@param callback function
function EventEmitter:on(event, callback)
  if not self.listeners[event] then
    self.listeners[event] = {}
  end
  table.insert(self.listeners[event], function(args)
    callback(utils.tbl_unpack(args))
  end)
end

---Subscribe a one-shot listener to a given event.
---@param event any Event identifier.
---@param callback function
function EventEmitter:once(event, callback)
  if not self.listeners[event] then
    self.listeners[event] = {}
  end
  local emitted = false
  table.insert(self.listeners[event], function(args)
    if not emitted then
      emitted = true
      callback(utils.tbl_unpack(args))
    end
  end)
end

---Add a new any-listener, subscribed to all events.
---@param callback function
function EventEmitter:on_any(callback)
  table.insert(self.any_listeners, function(event, args)
    callback(event, args)
  end)
end

---Add a new one-shot any-listener, subscribed to all events.
---@param callback function
function EventEmitter:once_any(callback)
  local emitted = false
  table.insert(self.any_listeners, function(event, args)
    if not emitted then
      emitted = true
      callback(event, utils.tbl_unpack(args))
    end
  end)
end

---Notify all listeners subscribed a given event.
---@param event any Event identifier.
---@param ... any Event callback args.
function EventEmitter:emit(event, ...)
  if not self.emit_lock[event] then
    local args = utils.tbl_pack(...)
    if type(self.listeners[event]) == "table" then
      for _, cb in ipairs(self.listeners[event]) do
        cb(args)
      end
    end
    for _, cb in ipairs(self.any_listeners) do
      cb(event, args)
    end
  end
end

---Non-recursively notify all listeners subscribed a given event.
---@param event any Event identifier.
---@param ... any Event callback args.
function EventEmitter:nore_emit(event, ...)
  if not self.emit_lock[event] then
    self.emit_lock[event] = true
    local args = utils.tbl_pack(...)

    if type(self.listeners[event]) == "table" then
      for _, cb in ipairs(self.listeners[event]) do
        cb(args)
      end
    end

    for _, cb in ipairs(self.any_listeners) do
      cb(event, args)
    end

    self.emit_lock[event] = false
  end
end

M.Event = Event
M.EventEmitter = EventEmitter
return M
