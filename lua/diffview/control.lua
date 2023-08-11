local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local async = require("diffview.async")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await

local M = {}

---@class Condvar : Waitable
---@operator call : Condvar
local Condvar = oop.create_class("Condvar", async.Waitable)
M.Condvar = Condvar

function Condvar:init()
  self.handles = {}
end

---@override
Condvar.await = async.sync_wrap(function(self, callback)
  table.insert(self.handles, callback)
end, 2)

function Condvar:notify_all()
  local len = #self.handles

  for i, cb in ipairs(self.handles) do
    if i > len then break end
    cb()
  end

  if #self.handles > len then
    self.handles = utils.vec_slice(self.handles, len + 1)
  else
    self.handles = {}
  end
end


---@class SignalConsumer : Waitable
---@operator call : SignalConsumer
---@field package parent Signal
local SignalConsumer = oop.create_class("SignalConsumer", async.Waitable)

function SignalConsumer:init(parent)
  self.parent = parent
end

---@override
---@param self SignalConsumer
SignalConsumer.await = async.sync_void(function(self)
  await(self.parent)
end)

---Check if the signal has been emitted.
---@return boolean
function SignalConsumer:check()
  return self.parent:check()
end

---Listen for the signal to be emitted. If the signal has already been emitted,
---the callback is invoked immediately. The callback can potentially be called
---multiple times if the signal is reset between emissions.
---@see Signal.reset
---@param callback fun(signal: Signal)
function SignalConsumer:listen(callback)
  self.parent:listen(callback)
end

function SignalConsumer:get_name()
  return self.parent:get_name()
end


---@class Signal : SignalConsumer
---@operator call : Signal
---@field package name string
---@field package emitted boolean
---@field package cond Condvar
---@field package listeners (fun(signal: Signal))[]
local Signal = oop.create_class("Signal", async.Waitable)
M.Signal = Signal

function Signal:init(name)
  self.name = name or "UNNAMED_SIGNAL"
  self.emitted = false
  self.cond = Condvar()
  self.listeners = {}
end

---@override
---@param self Signal
Signal.await = async.sync_void(function(self)
  if self.emitted then return end
  await(self.cond)
end)

---Send the signal.
function Signal:send()
  if self.emitted then return end
  self.emitted = true

  for _, listener in ipairs(self.listeners) do
    listener(self)
  end

  self.cond:notify_all()
end

---Listen for the signal to be emitted. If the signal has already been emitted,
---the callback is invoked immediately. The callback can potentially be called
---multiple times if the signal is reset between emissions.
---@see Signal.reset
---@param callback fun(signal: Signal)
function Signal:listen(callback)
  self.listeners[#self.listeners + 1] = callback
  if self.emitted then callback(self) end
end

---@return SignalConsumer
function Signal:new_consumer()
  return SignalConsumer(self)
end

---Check if the signal has been emitted.
---@return boolean
function Signal:check()
  return self.emitted
end

---Reset the signal such that it can be sent again.
function Signal:reset()
  self.emitted = false
end

function Signal:get_name()
  return self.name
end


---@class WorkPool : Waitable
---@operator call : WorkPool
---@field package workers table<Signal, boolean>
local WorkPool = oop.create_class("WorkPool", async.Waitable)
M.WorkPool = WorkPool

function WorkPool:init()
  self.workers = {}
end

---Check in a worker. Returns a "checkout" signal that must be used to resolve
---the work.
---@return Signal checkout
function WorkPool:check_in()
  local signal = Signal()
  self.workers[signal] = true

  signal:listen(function()
    self.workers[signal] = nil
  end)

  return signal
end

function WorkPool:size()
  return #vim.tbl_keys(self.workers)
end

---Wait for all workers to resolve and check out.
---@override
---@param self WorkPool
WorkPool.await = async.sync_void(function(self)
  local cur = next(self.workers)

  while cur do
    self.workers[cur] = nil
    await(cur)
    cur = next(self.workers)
  end
end)


---@class Permit : diffview.Object
---@operator call : Permit
---@field parent Semaphore
local Permit = oop.create_class("Permit")

function Permit:init(opt)
  self.parent = opt.parent
end

function Permit:destroy()
  self.parent = nil
end

---@param self Permit
function Permit:forget()
  if self.parent then
    local parent = self.parent
    self:destroy()
    parent:forget_one()
  end
end


---@class Semaphore : diffview.Object
---@operator call : Semaphore
---@field initial_count integer
---@field permit_count integer
---@field queue fun(p: Permit)[]
local Semaphore = oop.create_class("Semaphore")
M.Semaphore = Semaphore

function Semaphore:init(permit_count)
  assert(permit_count)
  self.initial_count = permit_count
  self.permit_count = permit_count
  self.queue = {}
end

function Semaphore:forget_one()
  if self.permit_count == self.initial_count then return end

  if next(self.queue) then
    local next_contractee = table.remove(self.queue, 1)
    next_contractee(Permit({ parent = self }))
  else
    self.permit_count = self.permit_count + 1
  end
end

---@param self Semaphore
---@param callback fun(permit: Permit)
Semaphore.acquire = async.wrap(function(self, callback)
  if self.permit_count <= 0 then
    table.insert(self.queue, callback)
    return
  end

  self.permit_count = self.permit_count - 1

  return callback(Permit({ parent = self }))
end)


---@class CountDownLatch : Waitable
---@operator call : CountDownLatch
---@field initial_count integer
---@field counter integer
---@field sem Semaphore
---@field condvar Condvar
---@field count_down fun(self: CountDownLatch)
local CountDownLatch = oop.create_class("CountDownLatch", async.Waitable)
M.CountDownLatch = CountDownLatch

function CountDownLatch:init(count)
  self.initial_count = count
  self.counter = count
  self.sem = Semaphore(1)
  self.condvar = Condvar()
end

function CountDownLatch:count_down()
  local permit = await(self.sem:acquire()) --[[@as Permit ]]

  if self.counter == 0 then
    -- The counter reached 0 while we were waiting for the permit
    permit:forget()
    return
  end

  self.counter = self.counter - 1
  permit:forget()

  if self.counter == 0 then
    self.condvar:notify_all()
  end
end

---@override
function CountDownLatch:await()
  if self.counter == 0 then return end
  await(self.condvar)
end

function CountDownLatch:reset()
  local permit = await(self.sem:acquire()) --[[@as Permit ]]
  self.counter = self.initial_count
  permit:forget()
  self.condvar:notify_all()
end

return M
