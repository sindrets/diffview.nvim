local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local control = lazy.require("diffview.control") ---@module "diffview.control"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await

local M = {}

---@generic T
---@class Stream<T> : diffview.Object
---@operator call : Stream
---@field src Stream.SrcFunc
---@field head integer
---@field drained boolean
local Stream = oop.create_class("Stream")
M.Stream = Stream

Stream.EOF = oop.Symbol("Stream.EOF");

---@alias Stream.SrcFunc fun(): (item: unknown, continue: boolean?)

---@param src table|Stream.SrcFunc
function Stream:init(src)
  self.src = self:create_src(src)
  self.head = 1
  self.drained = false
end

---@private
---@param src table|function
function Stream:create_src(src)
  if type(src) == "table" then
    if utils.islist(src) then
      local itr = ipairs(src)

      return function()
        local _, v = itr(src, self.head - 1)
        return v
      end
    else
      error("Unimplemented!")
    end
  else
    return src
  end
end

---@return unknown? item
---@return integer? index
function Stream:next()
  if self.drained then
    error("Attempted to consume a drained stream!")
  end

  local idx = self.head
  local v, cont = self.src()

  if v == Stream.EOF or (v == nil and not cont) then
    self.drained = true
    return Stream.EOF, nil
  end

  self.head = self.head + 1

  return v, idx
end

---@param n? integer
function Stream:skip(n)
  if not n then
    self:next()
    return
  end

  for _ = 1, n do self:next() end

  return self
end

---@return fun(): (index: integer, item: unknown)
function Stream:iter()
  return function()
    local v, i = self:next()
    ---@diagnostic disable-next-line: missing-return-value, return-type-mismatch
    if v == Stream.EOF then return nil end
    ---@cast i -?
    return i, v
  end
end

---@return unknown[]
function Stream:collect()
  local ret = {}
  for i, v in self:iter() do ret[i] = v end
  return ret
end

---@param first? integer (default: 1)
---@param last? integer (default: math.huge)
---@return Stream
function Stream:slice(first, last)
  if first == nil then first = 1 end
  if last == nil then last = math.huge end

  return Stream(function()
    if self.head > last then return nil, false end
    if first > self.head then
      self:skip(first - self.head)
    end

    return (self:next())
  end)
end

---@param f fun(item: unknown): unknown
---@return Stream
function Stream:map(f)
  return Stream(function()
    local v = self:next()

    while v ~= Stream.EOF do
      v = f(v)
      if v ~= nil then break end
      v = self:next()
    end

    if v == Stream.EOF then
      return nil, false
    end

    return v
  end)
end

---@param f fun(item: unknown): boolean
---@return Stream
function Stream:filter(f)
  return self:map(function(item)
    if not f(item) then
      return nil
    end

    return item
  end)
end

---@generic T
---@param f fun(acc: unknown, cur: unknown): T # Reducer
---@param init? any # Initial value of the accumulator. Defaults to the next value in the stream.
---@return T
function Stream:reduce(f, init)
  local acc = init
  if not acc then acc = self:next() end
  for _, v in self:iter() do acc = f(acc, v) end

  return acc
end

---@class AsyncStream : Stream, Waitable
---@operator call : AsyncStream
local AsyncStream = oop.create_class("AsyncStream", Stream)
M.AsyncStream = AsyncStream

AsyncStream.next = async.sync_wrap(
  ---@param self AsyncStream
  ---@param callback function
  function(self, callback)
    if self.drained then
      error("Attempted to consume a drained stream!")
    end

    local idx = self.head
    local v, cont = await(self.src())

    if v == Stream.EOF or (v == nil and not cont) then
      self.drained = true
      callback(Stream.EOF, nil)
      return
    end

    self.head = self.head + 1

    callback(v, idx)
  end
)

AsyncStream.await = async.sync_wrap(
  ---@param self AsyncStream
  ---@param callback function
  function(self, callback)
    callback(self:collect())
  end
)

---@enum StreamState
local StreamState = oop.enum({
  OPEN = 1,
  CLOSING = 2,
  CLOSED = 3,
})

---@class AsyncListStream : AsyncStream
---@operator call : AsyncListStream
---@field private data unknown[]
---@field private state { [AsyncListStream.EventKind]: { listeners: function[], args?: unknown[] } }
---@field private flow_state StreamState
---@field private sem Semaphore
---@field private close_listeners? (fun(...))[]
---@field private post_close_listeners (fun())[]
---@field private on_close_args? unknown[]
local AsyncListStream = oop.create_class("AsyncListStream", AsyncStream)
M.AsyncListStream = AsyncListStream

---@alias AsyncListStream.EventKind "on_close"|"on_post_close"

function AsyncListStream:init(opt)
  opt = opt or {}

  self.data = {}
  self.state = {
    on_close = { listeners = { opt.on_close } },
    on_post_close = { listeners = { opt.on_post_close } },
  }
  self.flow_state = StreamState.OPEN
  self.sem = control.Semaphore(1)

  local src = async.wrap(function(callback)
    if self.data[self.head] == nil then
      self.resume = callback
      return
    end

    callback(self.data[self.head])
  end)

  self:super(src)
end

---Append the given items to the end of the stream. Pushing `Stream.EOF` will
---close the stream.
function AsyncListStream:push(...)
  if self:is_closed() then return end
  local args = { ... }
  local permit = await(self.sem:acquire()) --[[@as Permit ]]

  for i = 1, select("#", ...) do
    if args[i] ~= nil then
      if args[i] == Stream.EOF then
        if self.flow_state ~= StreamState.CLOSING then
          self.flow_state = StreamState.CLOSING

          -- Release permit while calling 'on_close' callbacks so that they're
          -- able to invoke some final pushes before fully closing the stream.
          permit:forget()
          self:invoke_listeners("on_close")
          permit = await(self.sem:acquire()) --[[@as Permit ]]

          self.data[#self.data+1] = args[i]
          self.flow_state = StreamState.CLOSED

          self:invoke_listeners("on_post_close")

          break
        end
      else
        self.data[#self.data+1] = args[i]
      end
    end
  end

  permit:forget()

  if self.resume then
    local resume = self.resume
    self.resume = nil
    resume(self.data[self.head])
  end
end

---@param ... any Arguments to pass to the `on_close` callback.
function AsyncListStream:close(...)
  if self:is_closed() then return end
  self.state.on_close.args = utils.tbl_pack(...)
  self:push(Stream.EOF)
end

function AsyncListStream:is_closed()
  return self.flow_state == StreamState.CLOSED
end

---@param callback function
function AsyncListStream:on_close(callback)
  table.insert(self.state.on_close.listeners, callback)
end

---@param callback function
function AsyncListStream:on_post_close(callback)
  table.insert(self.state.on_post_close.listeners, callback)
end

---@private
---@param kind AsyncListStream.EventKind
function AsyncListStream:invoke_listeners(kind)
  local event_state = self.state[kind]

  for _, listener in ipairs(event_state.listeners) do
    if event_state.args then
      listener(utils.tbl_unpack(event_state.args))
    else
      listener()
    end
  end

  event_state.args = nil
end

return M
