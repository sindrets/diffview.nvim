local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

---@module "diffview.utils"
local utils = lazy.require("diffview.utils")

local M = {}

---@class Event

---@class EEvent
---@field FILES_STAGED Event
local Event = oop.enum({
  "FILES_STAGED",
})

---@alias ListenerType '"normal"'|'"once"'|'"any"'|'"any_once"'

---@class Listener
---@field type ListenerType
---@field callback function The original callback
---@field call function

---@class EventEmitter : Object
---@field event_map table<Event, Listener[]> # Registered events mapped to subscribed listeners.
---@field any_listeners Listener[] # Listeners subscribed to all events.
---@field emit_lock table<Event, boolean>
local EventEmitter = oop.create_class("EventEmitter")

---EventEmitter constructor.
---@return EventEmitter
function EventEmitter:init()
  self.event_map = {}
  self.any_listeners = {}
  self.emit_lock = {}
end

---Subscribe to a given event.
---@param event any Event identifier.
---@param callback function
function EventEmitter:on(event, callback)
  if not self.event_map[event] then
    self.event_map[event] = {}
  end
  table.insert(self.event_map[event], {
    type = "normal",
    callback = callback,
    call = function(args)
      callback(utils.tbl_unpack(args))
    end,
  })
end

---Subscribe a one-shot listener to a given event.
---@param event any Event identifier.
---@param callback function
function EventEmitter:once(event, callback)
  if not self.event_map[event] then
    self.event_map[event] = {}
  end
  local emitted = false
  table.insert(self.event_map[event], {
    type = "once",
    callback = callback,
    call = function(args)
      if not emitted then
        emitted = true
        self:off(callback, event)
        callback(utils.tbl_unpack(args))
      end
    end,
  })
end

---Add a new any-listener, subscribed to all events.
---@param callback function
function EventEmitter:on_any(callback)
  table.insert(self.any_listeners, {
    type = "any",
    callback = callback,
    call = function(event, args)
      callback(event, args)
    end,
  })
end

---Add a new one-shot any-listener, subscribed to all events.
---@param callback function
function EventEmitter:once_any(callback)
  local emitted = false
  table.insert(self.any_listeners, {
    type = "any_once",
    callback = callback,
    call = function(event, args)
      if not emitted then
        emitted = true
        callback(event, utils.tbl_unpack(args))
      end
    end,
  })
end

---Unsubscribe a listener. If no event is given, the listener is unsubscribed
---from all events.
---@param callback function
---@param event? any Only unsubscribe listeners from this event.
function EventEmitter:off(callback, event)
  ---@type Listener[][]
  local all
  if event then
    all = { self.event_map[event] }
  else
    all = utils.vec_join(
      vim.tbl_values(self.event_map),
      { self.any_listeners }
    )
  end

  for _, listeners in ipairs(all) do
    local remove = {}

    for i, listener in ipairs(listeners) do
      if listener.callback == callback then
        remove[#remove + 1] = i
      end
    end

    for i = #remove, 1, -1 do
      table.remove(listeners, remove[i])
    end
  end
end

---Clear all listeners for a given event. If no event is given: clear all listeners.
---@param event any?
function EventEmitter:clear(event)
  for e, _ in pairs(self.event_map) do
    if event == nil or event == e then
      self.event_map[e] = nil
    end
  end
end

---Notify all listeners subscribed to a given event.
---@param event any Event identifier.
---@param ... any Event callback args.
function EventEmitter:emit(event, ...)
  if not self.emit_lock[event] then
    local args = utils.tbl_pack(...)
    if type(self.event_map[event]) == "table" then
      for _, listener in ipairs(self.event_map[event]) do
        listener.call(args)
      end
    end
    for _, listener in ipairs(self.any_listeners) do
      listener.call(event, args)
    end
  end
end

---Non-recursively notify all listeners subscribed to a given event.
---@param event any Event identifier.
---@param ... any Event callback args.
function EventEmitter:nore_emit(event, ...)
  if not self.emit_lock[event] then
    self.emit_lock[event] = true
    local args = utils.tbl_pack(...)

    if type(self.event_map[event]) == "table" then
      for _, listener in ipairs(self.event_map[event]) do
        listener.call(args)
      end
    end

    for _, listener in ipairs(self.any_listeners) do
      listener.call(event, args)
    end

    self.emit_lock[event] = false
  end
end

---Get all listeners subscribed to the given event.
---@param event any Event identifier.
---@return Listener[]?
function EventEmitter:get(event)
  return self.event_map[event]
end

M.Event = Event
M.EventEmitter = EventEmitter
return M
