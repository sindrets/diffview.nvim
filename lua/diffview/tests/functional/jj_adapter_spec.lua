local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.vcs.adapters.jj", function()
  local JjAdapter = require("diffview.vcs.adapters.jj").JjAdapter
  local RevType = require("diffview.vcs.rev").RevType
  local arg_parser = require("diffview.arg_parser")

  ---@return JjAdapter
  local function new_adapter()
    local old_get_dir = JjAdapter.get_dir
    JjAdapter.get_dir = function(_)
      return "/tmp/.jj"
    end

    local adapter = JjAdapter({
      toplevel = "/tmp",
      path_args = {},
      cpath = nil,
    })

    JjAdapter.get_dir = old_get_dir

    adapter._rev_map = {
      ["@"] = "head_hash",
      ["@-"] = "parent_hash",
      ["root()"] = "root_hash",
      ["main"] = "main_hash",
      ["master"] = "master_hash",
      ["feature"] = "feature_hash",
    }

    adapter.resolve_rev_arg = function(_, rev)
      return adapter._rev_map[rev]
    end

    adapter.head_rev = function(_)
      return adapter.Rev(RevType.COMMIT, adapter._rev_map["@"] or "head_hash", true)
    end

    adapter.symmetric_diff_revs = function(_, _)
      return adapter.Rev(RevType.COMMIT, "merge_base_hash"), adapter.Rev(RevType.COMMIT, adapter._rev_map["@"])
    end

    adapter.has_bookmark = function(_, _)
      return true
    end

    return adapter
  end

  describe("parse_revs()", function()
    it("defaults to HEAD..LOCAL when no rev is provided", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs(nil, {})

      eq(RevType.COMMIT, left.type)
      eq("parent_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("parses single rev as COMMIT..LOCAL", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main", {})

      eq(RevType.COMMIT, left.type)
      eq("main_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("falls back from main to master when main bookmark is absent", function()
      local adapter = new_adapter()
      adapter.has_bookmark = function(_, name)
        return name == "master"
      end

      local left, right = adapter:parse_revs("main", {})

      eq(RevType.COMMIT, left.type)
      eq("master_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("parses double-dot range as COMMIT..COMMIT", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main..feature", {})

      eq(RevType.COMMIT, left.type)
      eq("main_hash", left.commit)
      eq(RevType.COMMIT, right.type)
      eq("feature_hash", right.commit)
    end)

    it("parses triple-dot range through symmetric merge-base resolution", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main...@", {})

      eq(RevType.COMMIT, left.type)
      eq("merge_base_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)
  end)

  describe("diffview_options()", function()
    it("accepts --selected-file and resolves rev args", function()
      local adapter = new_adapter()
      local argo = arg_parser.parse({ "main", "--selected-file=lua/diffview/init.lua" })
      local opt = adapter:diffview_options(argo)

      eq("main_hash", opt.left.commit)
      eq(RevType.LOCAL, opt.right.type)
      eq("lua/diffview/init.lua", opt.options.selected_file)
    end)
  end)

  describe("refresh_revs()", function()
    it("re-resolves symbolic revs", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main", {})

      adapter._rev_map["main"] = "next_main_hash"

      local new_left, new_right = adapter:refresh_revs("main", left, right)
      eq("next_main_hash", new_left.commit)
      eq(RevType.LOCAL, new_right.type)
    end)

    it("updates default baseline when parent changes", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs(nil, {})

      adapter._rev_map["@-"] = "next_parent_hash"

      local new_left, new_right = adapter:refresh_revs(nil, left, right)
      eq("next_parent_hash", new_left.commit)
      eq(RevType.LOCAL, new_right.type)
    end)
  end)

  describe("force_entry_refresh_on_noop()", function()
    it("returns true for ranges that include LOCAL", function()
      local adapter = new_adapter()
      local ok = adapter:force_entry_refresh_on_noop(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.LOCAL)
      )

      eq(true, ok)
    end)

    it("returns false for commit-to-commit ranges", function()
      local adapter = new_adapter()
      local ok = adapter:force_entry_refresh_on_noop(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.COMMIT, "right_hash")
      )

      eq(false, ok)
    end)
  end)

  describe("on_local_buffer_reused()", function()
    it("calls checktime on an unmodified buffer", function()
      local adapter = new_adapter()
      local bufnr = vim.api.nvim_create_buf(true, false)

      -- checktime requires a file on disk; write a temp file so the buffer
      -- has a real name and checktime doesn't error.
      local tmpfile = vim.fn.tempname()
      vim.fn.writefile({ "hello" }, tmpfile)
      vim.api.nvim_buf_set_name(bufnr, tmpfile)
      vim.fn.bufload(bufnr)

      -- Should not error.
      assert.has_no.errors(function()
        adapter:on_local_buffer_reused(bufnr)
      end)

      -- Buffer should still be loaded and valid.
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
      assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(tmpfile)
    end)
  end)

  describe("rev_to_args()", function()
    it("returns --from/--to for commit ranges", function()
      local adapter = new_adapter()
      local args = adapter:rev_to_args(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.COMMIT, "right_hash")
      )

      eq({ "--from", "left_hash", "--to", "right_hash" }, args)
    end)

    it("returns --from for commit..LOCAL", function()
      local adapter = new_adapter()
      local args = adapter:rev_to_args(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.LOCAL)
      )

      eq({ "--from", "left_hash" }, args)
    end)
  end)

  -- ------------------------------------------------------------------
  -- Integration tests: require jj
  -- ------------------------------------------------------------------
  describe("tracked_files", function()
    local async = require("diffview.async")
    local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
    local await = async.await

    local function jj_available()
      return vim.fn.executable("jj") == 1
    end

    local function run(cmd, cwd)
      local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
      assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
      return vim.trim(res.stdout or "")
    end

    local function create_jj_repo()
      local repo = vim.fn.tempname()
      vim.fn.mkdir(repo, "p")

      run({ "jj", "git", "init" }, repo)
      run({ "jj", "config", "set", "--repo", "user.name", "Test" }, repo)
      run({ "jj", "config", "set", "--repo", "user.email", "test@test.com" }, repo)

      return {
        dir = repo,
        jj = function(args)
          local cmd = { "jj" }
          vim.list_extend(cmd, args)
          return run(cmd, repo)
        end,
        write = function(relpath, content)
          local dir = vim.fn.fnamemodify(repo .. "/" .. relpath, ":h")
          vim.fn.mkdir(dir, "p")
          local f = assert(io.open(repo .. "/" .. relpath, "w"))
          f:write(content)
          f:close()
        end,
        adapter = function()
          JjAdapter.bootstrap.done = true
          JjAdapter.bootstrap.ok = true
          return JjAdapter({
            toplevel = repo,
            path_args = {},
          })
        end,
        cleanup = function()
          pcall(vim.fn.delete, repo, "rf")
        end,
      }
    end

    local repo

    before_each(function()
      if not jj_available() then
        pending("jj not installed")
        return
      end
      repo = create_jj_repo()
    end)

    after_each(function()
      if repo then repo.cleanup() end
    end)

    it("lists modified, added, and deleted files", helpers.async_test(function()
      if not jj_available() then pending("jj not installed") return end

      -- Initial commit with two files.
      repo.write("src/main.lua", 'print("v1")\n')
      repo.write("src/utils.lua", "local M = {}\nreturn M\n")
      repo.jj({ "describe", "-m", "initial" })
      repo.jj({ "new" })

      -- Modify one, delete one, add one.
      repo.write("src/main.lua", 'print("v2")\n')
      os.remove(repo.dir .. "/src/utils.lua")
      repo.write("src/new.lua", "new\n")

      local adapter = repo.adapter()
      local left = adapter.Rev(RevType.COMMIT, run({ "jj", "show", "-T", "commit_id", "@-", "--no-patch" }, repo.dir))
      local right = adapter.Rev(RevType.LOCAL)
      local args = adapter:rev_to_args(left, right)

      local err, files = await(adapter:tracked_files(
        left, right, args, "working",
        { default_layout = Diff2, merge_layout = Diff2 }
      ))

      assert.is_nil(err)

      local by_name = {}
      for _, file in ipairs(files) do
        local name = file.path:match("[^/]+$")
        by_name[name] = file
      end

      assert.is_not_nil(by_name["main.lua"], "main.lua should appear (modified)")
      assert.equals("M", by_name["main.lua"].status)

      assert.is_not_nil(by_name["new.lua"], "new.lua should appear (added)")
      assert.equals("A", by_name["new.lua"].status)

      assert.is_not_nil(by_name["utils.lua"], "utils.lua should appear (deleted)")
      assert.equals("D", by_name["utils.lua"].status)
    end))

    it("shows file content at a revision without errors", helpers.async_test(function()
      if not jj_available() then pending("jj not installed") return end

      repo.write("hello.txt", "hello world\n")
      repo.jj({ "describe", "-m", "add hello" })

      local adapter = repo.adapter()
      local commit_id = run({ "jj", "show", "-T", "commit_id", "@", "--no-patch" }, repo.dir)
      local rev = adapter.Rev(RevType.COMMIT, commit_id)

      local err, content = await(adapter:show("hello.txt", rev))

      assert.is_nil(err)
      assert.is_not_nil(content)
      assert.equals("hello world", vim.trim(table.concat(content, "\n")))
    end))

    it("paths do not contain revision specifiers", helpers.async_test(function()
      if not jj_available() then pending("jj not installed") return end

      repo.write("file.lua", "content\n")
      repo.jj({ "describe", "-m", "add file" })
      repo.jj({ "new" })
      repo.write("file.lua", "updated\n")

      local adapter = repo.adapter()
      local left = adapter.Rev(RevType.COMMIT, run({ "jj", "show", "-T", "commit_id", "@-", "--no-patch" }, repo.dir))
      local right = adapter.Rev(RevType.LOCAL)
      local args = adapter:rev_to_args(left, right)

      local err, files = await(adapter:tracked_files(
        left, right, args, "working",
        { default_layout = Diff2, merge_layout = Diff2 }
      ))

      assert.is_nil(err)
      assert.is_true(#files > 0)

      for _, file in ipairs(files) do
        -- Jujutsu paths should never contain revision specifiers.
        assert.is_nil(file.path:match("@"), ("path %q contains @"):format(file.path))
        assert.is_nil(file.path:match("#%d+"), ("path %q contains #rev"):format(file.path))
      end
    end))
  end)
end)
