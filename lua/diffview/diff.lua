--[[
-- An implementation of Myers' diff algorithm
-- Derived from: https://github.com/Swatinem/diff
--]]
local oop = require("diffview.oop")
local M = {}

---@class EditToken
---@field NOOP integer
---@field DELETE integer
---@field INSERT integer
---@field REPLACE integer
local EditToken = oop.enum({
  "NOOP",
  "DELETE",
  "INSERT",
  "REPLACE",
})

---@class Diff : Object
---@field a any[]
---@field b any[]
---@field moda boolean[]
---@field modb boolean[]
---@field up table<integer, integer>
---@field down table<integer, integer>
---@field eql_fn function
local Diff = oop.create_class("Diff")

---Diff constructor.
---@param a any[]
---@param b any[]
---@param eql_fn function|nil
---@return Diff
function Diff:init(a, b, eql_fn)
  self.a = a
  self.b = b
  self.moda = {}
  self.modb = {}
  self.up = {}
  self.down = {}
  self.eql_fn = eql_fn or function(aa, bb)
    return aa == bb
  end

  for i = 1, #a do
    self.moda[i] = false
  end
  for i = 1, #b do
    self.modb[i] = false
  end

  self:lcs(1, #self.a + 1, 1, #self.b + 1)
end

function Diff:create_edit_script()
  local astart = 1
  local bstart = 1
  local aend = #self.moda
  local bend = #self.modb
  local script = {}

  while astart <= aend or bstart <= bend do
    if astart <= aend and bstart <= bend then
      if not self.moda[astart] and not self.modb[bstart] then
        table.insert(script, EditToken.NOOP)
        astart = astart + 1
        bstart = bstart + 1
        goto continue
      elseif self.moda[astart] and self.modb[bstart] then
        table.insert(script, EditToken.REPLACE)
        astart = astart + 1
        bstart = bstart + 1
        goto continue
      end
    end

    if astart <= aend and (bstart > bend or self.moda[astart]) then
      table.insert(script, EditToken.DELETE)
      astart = astart + 1
    end

    if bstart <= bend and (astart > aend or self.modb[bstart]) then
      table.insert(script, EditToken.INSERT)
      bstart = bstart + 1
    end

    ::continue::
  end

  return script
end

function Diff:lcs(astart, aend, bstart, bend)
  -- separate common head
  while astart < aend and bstart < bend and self.eql_fn(self.a[astart], self.b[bstart]) do
    astart = astart + 1
    bstart = bstart + 1
  end

  -- separate common tail
  while astart < aend and bstart < bend and self.eql_fn(self.a[aend - 1], self.b[bend - 1]) do
    aend = aend - 1
    bend = bend - 1
  end

  if astart == aend then
    -- only insertions
    while bstart < bend do
      self.modb[bstart] = true
      bstart = bstart + 1
    end
  elseif bend == bstart then
    -- only deletions
    while astart < aend do
      self.moda[astart] = true
      astart = astart + 1
    end
  else
    local snake = self:snake(astart, aend, bstart, bend)
    self:lcs(astart, snake.x, bstart, snake.y)
    self:lcs(snake.u, aend, snake.v, bend)
  end
end

function Diff:snake(astart, aend, bstart, bend)
  local N = aend - astart
  local MM = bend - bstart

  local kdown = astart - bstart
  local kup = aend - bend

  local delta = N - MM
  local deltaOdd = delta % 2 ~= 0

  self.down[kdown + 1] = astart
  self.up[kup - 1] = aend

  local Dmax = (N + MM) / 2 + 1

  for D = 0, Dmax do
    local x, y

    -- Forward path
    for k = kdown - D, kdown + D, 2 do
      if k == kdown - D then
        x = self.down[k + 1] -- down
      else
        x = self.down[k - 1] + 1 -- right
        if k < kdown + D and self.down[k + 1] >= x then
          x = self.down[k + 1] -- down
        end
      end
      y = x - k

      while x < aend and y < bend and self.eql_fn(self.a[x], self.b[y]) do
        x = x + 1
        y = y + 1 -- diagonal
      end
      self.down[k] = x

      if deltaOdd and kup - D < k and k < kup + D and self.up[k] <= self.down[k] then
        return {
          x = self.down[k],
          y = self.down[k] - k,
          u = self.up[k],
          v = self.up[k] - k,
        }
      end
    end

    -- Reverse path
    for k = kup - D, kup + D, 2 do
      if k == kup + D then
        x = self.up[k - 1] -- up
      else
        x = self.up[k + 1] - 1 -- left
        if k > kup - D and self.up[k - 1] < x then
          x = self.up[k - 1] -- up
        end
      end
      y = x - k

      while x > astart and y > bstart and self.eql_fn(self.a[x - 1], self.b[y - 1]) do
        x = x - 1
        y = y - 1 -- diagonal
      end
      self.up[k] = x

      if not deltaOdd and kdown - D <= k and k <= kdown + D and self.up[k] <= self.down[k] then
        return {
          x = self.down[k],
          y = self.down[k] - k,
          u = self.up[k],
          v = self.up[k] - k,
        }
      end
    end
  end

  error("Unexpected state!")
end

function M._test_exec(a, b, script)
  local ai = 1
  local bi = 1

  for _, opr in ipairs(script) do
    if opr == EditToken.NOOP then
      ai = ai + 1
      bi = bi + 1
    elseif opr == EditToken.DELETE then
      table.remove(a, ai)
    elseif opr == EditToken.INSERT then
      table.insert(a, ai, b[bi])
      ai = ai + 1
      bi = bi + 1
    elseif opr == EditToken.REPLACE then
      table.remove(a, ai)
      table.insert(a, ai, b[bi])
      ai = ai + 1
      bi = bi + 1
    end
  end
end

function M._test_diff(a, b)
  local diff = Diff(a, b)
  local script = diff:create_edit_script()
  print("a", vim.inspect(a))
  print("b", vim.inspect(b))
  print("script", vim.inspect(script))
  M._test_exec(a, b, script)
  print("result", vim.inspect(a))
end

function M._test()
  -- deletion
  local a = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  local b = { 1, 2, 5, 6, 8, 9 }
  M._test_diff(a, b)

  -- insertion
  a = { 1, 2, 5, 6, 8, 9 }
  b = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  M._test_diff(a, b)

  -- deletion, insertion, replacement
  a = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  b = { 1, 2, 10, 11, 5, 6, 12, 13, 8 }
  M._test_diff(a, b)
end

M.EditToken = EditToken
M.Diff = Diff
return M
