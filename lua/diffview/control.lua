local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local async = require("diffview.async")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await

local M = {}

---@class Condvar : Waitable
---@operator call : Condvar
local Condvar = oop.create_class("Condvar", async.Waitable)

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

function Semaphore:init(permit_count)
  assert(permit_count)
  self.initial_count = permit_count
  self.permit_count = permit_count
  self.queue = {}
end

function Semaphore:forget_one()
  if self.permit_count == self.initial_count then return end

  if next(self.queue) then
    local next_contractor = table.remove(self.queue, 1)
    next_contractor(Permit({ parent = self }))
  else
    self.permit_count = self.permit_count + 1
  end
end

---@param self Semaphore
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

M.CountDownLatch = CountDownLatch
M.Semaphore = Semaphore
M.Condvar = Condvar

return M
