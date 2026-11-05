local diffview = require("diffview")
local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.completion", function()
  local get_adapter

  before_each(function()
    get_adapter = diffview.get_adapter
  end)

  after_each(function()
    diffview.get_adapter = get_adapter
  end)

  it("handles a large number of revision candidates", function()
    local revisions = {}
    for i = 1, 10000 do
      revisions[i] = "branch-" .. i
    end

    diffview.get_adapter = function()
      return {
        comp = {
          open = {
            get_all_names = function()
              return {}
            end,
          },
        },
        rev_candidates = function()
          return revisions
        end,
      }
    end

    local cmd_line = "DiffviewOpen "
    eq(revisions, diffview.completion("", cmd_line, #cmd_line))
  end)
end)
