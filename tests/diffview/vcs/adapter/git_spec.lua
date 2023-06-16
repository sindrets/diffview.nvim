local helpers = require("tests.diffview.helpers.init")

local eq = helpers.smart_same
local neq = helpers.smart_nsame

describe("diffview.vcs.adapters.git", function()
  describe("file-history", function()
    describe("parse_fh_data()", function()
      it("parses common data correctly", function()
        local data = {
          left_hash = "0000000000000000000000000000000000000000",
          right_hash = "0000000000000000000000000000000000000000",
          namestat = {
            [[M	foo/bar/baz.txt]],
          },
          numstat = {
            [[4	12	foo/bar/baz.txt]],
          },
        }

        local commit = helpers.git.new_dummy_commit()
        local adapter = helpers.git.new_dummy_adapter()
        local fh_state = {
          layout_opt = {},
          prepared_log_opts = {},
          single_file = true,
        }

        local ok, entry = adapter:parse_fh_data(data, commit, fh_state)

        eq(ok, true)
        eq(#entry.files, 1)
        eq(entry.files[1].path, "foo/bar/baz.txt")
        eq(entry.files[1].status, "M")
        eq(entry.files[1].stats.additions, 4)
        eq(entry.files[1].stats.deletions, 12)
      end)

      it("parses renames correctly", function()
        local data = {
          left_hash = "0000000000000000000000000000000000000000",
          right_hash = "0000000000000000000000000000000000000000",
          namestat = {
            [[R097	foo/bar/baz.txt	foo/bar/qux.txt]],
          },
          numstat = {
            [[4	12	foo/bar/{foo.txt -> qux.txt}]],
          },
        }

        local commit = helpers.git.new_dummy_commit()
        local adapter = helpers.git.new_dummy_adapter()
        local fh_state = {
          layout_opt = {},
          prepared_log_opts = {},
          single_file = true,
        }

        local ok, entry = adapter:parse_fh_data(data, commit, fh_state)

        eq(ok, true)
        eq(#entry.files, 1)
        eq(entry.files[1].path, "foo/bar/qux.txt")
        eq(entry.files[1].status, "R")
        eq(entry.files[1].stats.additions, 4)
        eq(entry.files[1].stats.deletions, 12)
        eq(fh_state.old_path, "foo/bar/baz.txt")
      end)

      it("handles stats for binary files correctly", function()
        local data = {
          left_hash = "0000000000000000000000000000000000000000",
          right_hash = "0000000000000000000000000000000000000000",
          namestat = {
            [[M	foo/bar/baz.txt]],
          },
          numstat = {
            [[-	-	foo/bar/baz.txt]],
          },
        }

        local commit = helpers.git.new_dummy_commit()
        local adapter = helpers.git.new_dummy_adapter()
        local fh_state = {
          layout_opt = {},
          prepared_log_opts = {},
          single_file = true,
        }

        local ok, entry = adapter:parse_fh_data(data, commit, fh_state)

        eq(ok, true)
        eq(#entry.files, 1)
        eq(entry.files[1].path, "foo/bar/baz.txt")
        eq(entry.files[1].stats, nil)
      end)
    end)
  end)
end)
