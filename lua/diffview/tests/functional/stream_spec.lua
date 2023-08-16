local async = require("diffview.async")
local helpers = require("diffview.tests.helpers")

local await = async.await
local async_test = helpers.async_test
local eq, neq = helpers.eq, helpers.neq

describe("diffview.stream", function()
  local Stream = require("diffview.stream").Stream
  local AsyncStream = require("diffview.stream").AsyncStream
  local AsyncListStream = require("diffview.stream").AsyncListStream

  local arr1 = {
    { name = "a", i = 1 },
    { name = "b", i = 2 },
    { name = "c", i = 3 },
    { name = "d", i = 4 },
    { name = "e", i = 5 },
  }

  describe("Stream", function()
    it("can collect a simple array", function()
      eq(arr1, Stream(arr1):collect())
    end)

    it("can iterate a simple array", function()
      local s0 = {}
      local s1 = {}

      for i, v in ipairs(arr1) do
        s0[#s0+1] = { i, v }
      end

      for i, v in Stream(arr1):iter() do
        s1[#s1 + 1] = { i, v }
      end

      eq(s0, s1)
    end)

    it("can slice", function()
      eq(
        vim.list_slice(arr1, 2, 4),
        Stream(arr1):slice(2, 4):collect()
      )
    end)

    it("can map", function()
      local function f(item)
        return item.name:upper():rep(5)
      end

      eq(
        vim.tbl_map(f, arr1),
        Stream(arr1):map(f):collect()
      )
    end)

    it("can filter", function()
      local function f(item)
        return item.i % 2 ~= 0
      end

      eq(
        vim.tbl_filter(f, arr1),
        Stream(arr1):filter(f):collect()
      )
    end)

    it("can reduce without an init value", function()
      eq(
        "abcde",
        Stream({ "a", "b", "c", "d", "e" }):reduce(function(acc, cur)
          return acc .. cur
        end)
      )
    end)

    it("can reduce with an init value", function()
      eq(
        "init abcde",
        Stream(arr1):reduce(function(acc, cur)
          return acc .. cur.name
        end, "init ")
      )
    end)

    it("can run a pipeline of transforms", function()
      eq(
        "AAAAACCCCCEEEEE",
        Stream(arr1)
          :filter(function(item)
            return item.i % 2 ~= 0
          end)
          :map(function(item)
            return item.name:upper():rep(5)
          end)
          :reduce(function(acc, cur)
            return acc .. cur
          end, "")
      )
    end)
  end)

  describe("AsyncStream", function()
    local function mock_iter(src_arr)
      src_arr = src_arr or arr1
      local iter = ipairs(src_arr)
      local i = 0

      return async.wrap(function(callback)
        if i == #src_arr then return callback(nil) end
        await(async.timeout(1))
        local _, ret = iter(src_arr, i)
        i = i + 1
        return callback(ret)
      end)
    end

    it("can iterate", async_test(function()
      local s0 = {}
      local s1 = {}

      for i, v in ipairs(arr1) do
        s0[#s0+1] = { i, v }
      end

      for i, v in AsyncStream(mock_iter(arr1)):iter() do
        s1[#s1 + 1] = { i, v }
      end

      eq(s0, s1)
    end))

    it("can be awaited", async_test(function()
      local stream = AsyncStream(mock_iter(arr1))
      eq(arr1, await(stream))
    end))
  end)

  describe("AsyncListStream", function()
    local mock_worker = async.void(function(stream, src_array)
      for _, v in ipairs(src_array or arr1) do
        await(async.timeout(10))
        stream:push(v)
      end
      stream:close()
    end)

    it("can iterate", async_test(function()
      local s0 = {}
      local s1 = {}

      for i, v in ipairs(arr1) do
        s0[#s0+1] = { i, v }
      end

      local stream = AsyncListStream()
      mock_worker(stream)

      for i, v in stream:iter() do
        s1[#s1 + 1] = { i, v }
      end

      eq(s0, s1)
    end))

    it("can be awaited", async_test(function()
      local stream = AsyncListStream()
      mock_worker(stream)

      eq(arr1, await(stream))
    end))

    it("can close early", async_test(function()
      local stream = AsyncListStream()
      mock_worker(stream)

      local ret = {}
      for i, v in stream:iter() do
        ret[i] = v
        if i == 3 then stream:close() end
      end

      eq(vim.list_slice(arr1, 1, 3), ret)
    end))

    it("can't push items after close", async_test(function()
      local stream = AsyncListStream()
      stream:push(1, 2, 3)
      stream:close()
      stream:push(4, 5, 6)

      eq({ 1, 2, 3 }, stream:collect())
    end))

    it("can push final items during on_close()", async_test(function()
      local final_arr = { "final_1", "final_2", "final_3" }
      local stream
      stream = AsyncListStream({
        on_close = function()
          stream:push(unpack(final_arr))
        end,
      })
      mock_worker(stream)

      local ret = {}
      for i, v in stream:iter() do
        ret[i] = v
        if i == 3 then stream:close() end
      end

      eq(
        vim.list_extend(vim.list_slice(arr1, 1, 3), final_arr),
        ret
      )
    end))

    it("calls on_close() callbacks with the appropriate args", async.sync_wrap(function(done)
      local stream = AsyncListStream({
        on_close = function(...)
          eq({ nil, 1, nil, 2, 3 }, { ... })
          done()
        end,
      })
      stream:close(nil, 1, nil, 2, 3)
    end))

    it("calls the event callbacks in the appropriate order", async_test(function()
      local ret = {}
      local stream = AsyncListStream({
        on_close = function()
          table.insert(ret, 1)
        end,
        on_post_close = function()
          table.insert(ret, 2)
        end,
      })

      stream:close()
      await(stream)
      eq({ 1, 2 }, ret)
    end))
  end)
end)
