local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@enum EventName
local EventName = oop.enum({
  FILES_STAGED = 1,
})

---@alias ListenerType "normal"|"once"|"any"|"any_once"
---@alias ListenerCallback (fun(e: Event, ...): boolean?)

---@class Listener
---@field type ListenerType
---@field callback ListenerCallback The original callback
---@field call function

---@class Event : diffview.Object
---@operator call : Event
---@field id any
---@field propagate boolean
local Event = oop.create_class("Event")

function Event:init(opt)
  self.id = opt.id
  self.propagate = true
end

function Event:stop_propagation()
  self.propagate = false
end


---@class EventEmitter : diffview.Object
---@operator call : EventEmitter
---@field event_map table<any, Listener[]> # Registered events mapped to subscribed listeners.
---@field any_listeners Listener[] # Listeners subscribed to all events.
---@field emit_lock table<any, boolean>
local EventEmitter = oop.create_class("EventEmitter")

---EventEmitter constructor.
function EventEmitter:init()
  self.event_map = {}
  self.any_listeners = {}
  self.emit_lock = {}
end

---Subscribe to a given event.
---@param event_id any Event identifier.
---@param callback ListenerCallback
function EventEmitter:on(event_id, callback)
  if not self.event_map[event_id] then
    self.event_map[event_id] = {}
  end

  table.insert(self.event_map[event_id], 1, {
    type = "normal",
    callback = callback,
    call = function(event, args)
      return callback(event, utils.tbl_unpack(args))
    end,
  })
end

---Subscribe a one-shot listener to a given event.
---@param event_id any Event identifier.
---@param callback ListenerCallback
function EventEmitter:once(event_id, callback)
  if not self.event_map[event_id] then
    self.event_map[event_id] = {}
  end

  local emitted = false

  table.insert(self.event_map[event_id], 1, {
    type = "once",
    callback = callback,
    call = function(event, args)
      if not emitted then
        emitted = true
        return callback(event, utils.tbl_unpack(args))
      end
    end,
  })
end

---Add a new any-listener, subscribed to all events.
---@param callback ListenerCallback
function EventEmitter:on_any(callback)
  table.insert(self.any_listeners, 1, {
    type = "any",
    callback = callback,
    call = function(event, args)
      return callback(event, args)
    end,
  })
end

---Add a new one-shot any-listener, subscribed to all events.
---@param callback ListenerCallback
function EventEmitter:once_any(callback)
  local emitted = false

  table.insert(self.any_listeners, 1, {
    type = "any_once",
    callback = callback,
    call = function(event, args)
      if not emitted then
        emitted = true
        return callback(event, utils.tbl_unpack(args))
      end
    end,
  })
end

---Unsubscribe a listener. If no event is given, the listener is unsubscribed
---from all events.
---@param callback function
---@param event_id? any Only unsubscribe listeners from this event.
function EventEmitter:off(callback, event_id)
  ---@type Listener[][]
  local all

  if event_id then
    all = { self.event_map[event_id] }
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
---@param event_id any?
function EventEmitter:clear(event_id)
  for e, _ in pairs(self.event_map) do
    if event_id == nil or event_id == e then
      self.event_map[e] = nil
    end
  end
end

---@param listeners Listener[]
---@param event Event
---@param args table
---@return Listener[]
local function filter_call(listeners, event, args)
  listeners = utils.vec_slice(listeners) --[[@as Listener[] ]]
  local result = {}

  for i = 1, #listeners do
    local cur = listeners[i]
    local ret = cur.call(event, args)
    local discard = (type(ret) == "boolean" and ret)
        or cur.type == "once"
        or cur.type == "any_once"

    if not discard then result[#result + 1] = cur end

    if not event.propagate then
      for j = i + 1, #listeners do result[j] = listeners[j] end
      break
    end
  end

  return result
end

---Notify all listeners subscribed to a given event.
---@param event_id any Event identifier.
---@param ... any Event callback args.
function EventEmitter:emit(event_id, ...)
  if not self.emit_lock[event_id] then
    local args = utils.tbl_pack(...)
    local e = Event({ id = event_id })

    if type(self.event_map[event_id]) == "table" then
      self.event_map[event_id] = filter_call(self.event_map[event_id], e, args)
    end

    if e.propagate then
      self.any_listeners = filter_call(self.any_listeners, e, args)
    end
  end
end

---Non-recursively notify all listeners subscribed to a given event.
---@param event_id any Event identifier.
---@param ... any Event callback args.
function EventEmitter:nore_emit(event_id, ...)
  if not self.emit_lock[event_id] then
    self.emit_lock[event_id] = true
    local args = utils.tbl_pack(...)
    local e = Event({ id = event_id })

    if type(self.event_map[event_id]) == "table" then
      self.event_map[event_id] = filter_call(self.event_map[event_id], e, args)
    end

    if e.propagate then
      self.any_listeners = filter_call(self.any_listeners, e, args)
    end

    self.emit_lock[event_id] = false
  end
end

---Get all listeners subscribed to the given event.
---@param event_id any Event identifier.
---@return Listener[]?
function EventEmitter:get(event_id)
  return self.event_map[event_id]
end

M.EventName = EventName
M.Event = Event
M.EventEmitter = EventEmitter

return M
