local async = require("diffview.async")
local helpers = require("diffview.tests.helpers")

local await = async.await
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
    it("collects simple array", function()
      eq(arr1, Stream(arr1):collect())
    end)

    it("iterates simple array", function()
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

    it("slices", function()
      eq(
        vim.list_slice(arr1, 2, 4),
        Stream(arr1):slice(2, 4):collect()
      )
    end)

    it("maps", function()
      local function f(item)
        return item.name:upper():rep(5)
      end

      eq(
        vim.tbl_map(f, arr1),
        Stream(arr1):map(f):collect()
      )
    end)

    it("filters", function()
      local function f(item)
        return item.i % 2 ~= 0
      end

      eq(
        vim.tbl_filter(f, arr1),
        Stream(arr1):filter(f):collect()
      )
    end)

    it("reduces without init value", function()
      eq(
        15,
        Stream({ 1, 2, 3, 4, 5 }):reduce(function(acc, cur)
          return acc + cur
        end)
      )
    end)

    it("reduces with init value", function()
      eq(
        "reduced names: abcde",
        Stream(arr1):reduce(function(acc, cur)
          return acc .. cur.name
        end, "reduced names: ")
      )
    end)

    it("runs a pipeline of transforms", function()
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
    it("can iterate", helpers.async_test(function()
      local iter = ipairs(arr1)
      local i = 0

      eq(
        arr1,
        AsyncStream(
          async.wrap(function(callback)
            if i == #arr1 then return callback(nil) end
            await(async.timeout(1))
            local _, ret = iter(arr1, i)
            i = i + 1
            return callback(ret)
          end)
        ):collect()
      )
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

    it("can iterate", helpers.async_test(function()
      local stream = AsyncListStream()
      mock_worker(stream)
      eq(arr1, stream:collect())
    end))

    it("can close early", helpers.async_test(function()
      local stream = AsyncListStream()
      mock_worker(stream)

      local ret = {}
      for i, v in stream:iter() do
        ret[i] = v
        if i == 3 then stream:close() end
      end

      eq(vim.list_slice(arr1, 1, 3), ret)
    end))

    it("can push final items during on_close()", helpers.async_test(function()
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

    it("can be awaited", helpers.async_test(function()
      local stream = AsyncListStream()
      mock_worker(stream)

      eq(arr1, await(stream))
    end))
  end)
end)
