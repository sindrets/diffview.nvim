local oop = require("diffview.oop")
local async = require("plenary.async")
local Semaphore = require("plenary.async.control").Semaphore
local Condvar = require("plenary.async.control").Condvar
local channel = require("plenary.async.control").channel

local M = {}

---@class Condvar
---@field wait function
---@field notify_one function
---@field notify_all function

---@class Semaphore
---@field acquire function

---@class CountDownLatch : Object
---@field initial_count integer
---@field counter integer
---@field sem Semaphore
---@field condvar Condvar
---@field count_down fun(self: CountDownLatch)
local CountDownLatch = oop.create_class("CountDownLatch")

function CountDownLatch:init(count)
  self.initial_count = count
  self.counter = count
  self.sem = Semaphore.new(1)
  self.condvar = Condvar.new()
end

CountDownLatch.count_down = async.void(function(self)
  local permit = self.sem:acquire()
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
end)

function CountDownLatch:await()
  if self.counter == 0 then
    return
  end

  self.condvar:wait()
end

function CountDownLatch:reset()
  local permit = self.sem:acquire()
  self.counter = self.initial_count
  permit:forget()
  self.condvar:notify_all()
end

M.CountDownLatch = CountDownLatch
M.Semaphore = Semaphore
M.Condvar = Condvar
M.channel = channel
return M
