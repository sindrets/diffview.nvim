local async = require("diffview.async")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local P4Adapter = require("diffview.vcs.adapters.p4").P4Adapter
local P4Rev = require("diffview.vcs.adapters.p4.rev").P4Rev
local RevType = require("diffview.vcs.rev").RevType
local test_utils = require("diffview.tests.helpers")

local await = async.await

--- Run a shell command synchronously.
local function run(cmd, cwd, env)
  local res = vim.system(cmd, { cwd = cwd, text = true, env = env }):wait()
  assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
  return vim.trim(res.stdout or "")
end

--- Return true when both `p4` and `p4d` are available on $PATH.
local function p4_available()
  return vim.fn.executable("p4") == 1 and vim.fn.executable("p4d") == 1
end

--- Create a disposable Perforce repository using rsh-mode (no daemon).
--- Returns a table with env vars and a cleanup function.
local function create_p4_repo()
  local p4root = vim.fn.tempname()
  vim.fn.mkdir(p4root, "p")

  local workspace = vim.fn.tempname()
  vim.fn.mkdir(workspace, "p")

  local p4port = ("rsh:p4d -r %s -i"):format(p4root)
  local p4user = "testuser"
  local p4client = "testclient"

  local env = {
    P4PORT = p4port,
    P4USER = p4user,
    P4CLIENT = p4client,
  }

  -- Initialise the server database.
  run({ "p4d", "-r", p4root, "-jr", "/dev/null" }, nil, env)

  -- Create a client workspace.
  local spec = run({ "p4", "client", "-o", p4client }, workspace, env)
  spec = spec:gsub("Root:\t[^\n]+", "Root:\t" .. workspace)
  vim.fn.system(
    { "p4", "-p", p4port, "-u", p4user, "client", "-i" },
    spec
  )

  --- Build common p4 flags including -d for the workspace directory.
  local base_args = { "p4", "-p", p4port, "-u", p4user, "-c", p4client, "-d", workspace }

  return {
    root = p4root,
    workspace = workspace,
    env = env,
    --- Run a p4 command inside the workspace.
    p4 = function(args)
      local cmd = vim.list_extend({}, base_args)
      vim.list_extend(cmd, args)
      return run(cmd, workspace, env)
    end,
    --- Write a file relative to the workspace root.
    write = function(relpath, content)
      local dir = vim.fn.fnamemodify(workspace .. "/" .. relpath, ":h")
      vim.fn.mkdir(dir, "p")
      local f = assert(io.open(workspace .. "/" .. relpath, "w"))
      f:write(content)
      f:close()
    end,
    --- Set P4 environment variables so that child processes spawned by the
    --- adapter connect to this test server.  Returns the previous values so
    --- they can be restored in cleanup.
    set_env = function()
      local prev = {
        P4PORT = vim.env.P4PORT,
        P4USER = vim.env.P4USER,
        P4CLIENT = vim.env.P4CLIENT,
      }
      vim.env.P4PORT = p4port
      vim.env.P4USER = p4user
      vim.env.P4CLIENT = p4client
      return prev
    end,
    --- Create a P4Adapter pointing at this workspace.  Also sets the
    --- environment so that adapter-spawned jobs connect to this server.
    adapter = function(self)
      self._prev_env = self:set_env()
      -- Mark bootstrap as done+ok so the adapter doesn't try `p4 info`
      -- against a potentially stale connection during construction.
      P4Adapter.bootstrap.done = true
      P4Adapter.bootstrap.ok = true
      return P4Adapter({
        toplevel = workspace,
        path_args = {},
      })
    end,
    cleanup = function(self)
      if self._prev_env then
        for k, v in pairs(self._prev_env) do
          vim.env[k] = v
        end
      end
      pcall(vim.fn.delete, p4root, "rf")
      pcall(vim.fn.delete, workspace, "rf")
    end,
  }
end

describe("diffview.vcs.adapters.p4", function()
  -- ------------------------------------------------------------------
  -- Unit tests: parsing helpers (no Perforce installation needed)
  -- ------------------------------------------------------------------
  describe("P4Rev", function()
    it("object_name returns the revision specifier for COMMIT revs", function()
      local rev = P4Rev(RevType.COMMIT, "#head")
      assert.equals("#head", rev:object_name())

      rev = P4Rev(RevType.COMMIT, "@12345")
      assert.equals("@12345", rev:object_name())
    end)

    it("converts numeric revision to @CL format", function()
      local rev = P4Rev(RevType.COMMIT, 42)
      assert.equals("@42", rev:object_name())
    end)

    it("object_name returns @ for LOCAL revs", function()
      local rev = P4Rev(RevType.LOCAL)
      assert.equals("@", rev:object_name())
    end)

    it("is_head returns true only for #head", function()
      assert.is_true(P4Rev(RevType.COMMIT, "#head"):is_head())
      assert.is_falsy(P4Rev(RevType.COMMIT, "@100"):is_head())
    end)

    it("new_null_tree creates a #none rev", function()
      local rev = P4Rev.new_null_tree()
      assert.equals("#none", rev:object_name())
    end)

    it("to_range formats single and double revision strings", function()
      assert.equals("@1,@5", P4Rev.to_range(P4Rev(RevType.COMMIT, "@1"), P4Rev(RevType.COMMIT, "@5")))
      assert.equals("@1", P4Rev.to_range(P4Rev(RevType.COMMIT, "@1")))
      assert.equals("@1", P4Rev.to_range(P4Rev(RevType.COMMIT, "@1"), P4Rev(RevType.COMMIT, "@1")))
    end)
  end)

  describe("get_show_args", function()
    it("appends revision specifier to depot path", function()
      local adapter = P4Adapter({ toplevel = "/tmp", path_args = {} })
      local args = adapter:get_show_args("//depot/foo.lua", P4Rev(RevType.COMMIT, "#head"))
      -- Should produce: { "print", "-q", "//depot/foo.lua#head" }
      assert.equals("print", args[1])
      assert.equals("-q", args[2])
      assert.equals("//depot/foo.lua#head", args[3])
    end)

    it("does not double-append revision specifiers", function()
      local adapter = P4Adapter({ toplevel = "/tmp", path_args = {} })
      -- Path should NOT already contain #rev -- that was the original bug.
      local args = adapter:get_show_args("//depot/foo.lua", P4Rev(RevType.COMMIT, "@42"))
      assert.equals("//depot/foo.lua@42", args[3])
      -- Verify no double specifier.
      assert.is_nil(args[3]:match("#%d+[@#]"))
      assert.is_nil(args[3]:match("@%d+[@#]"))
    end)
  end)

  describe("parse_describe_output", function()
    local parse = require("diffview.vcs.adapters.p4.commit").parse_describe_output

    it("extracts file paths without revision suffixes", function()
      -- Simulate the output of `p4 describe <CL>`.  Real output has a
      -- blank line between "Affected files ..." and the first entry.
      local output = {
        "Change 42 on 2025/01/15 by user@client *pending*",
        "",
        "\tFix a bug",
        "",
        "Affected files ...",
        "",
        "... //depot/src/main.lua#3 edit",
        "... //depot/src/utils.lua#1 add",
        "... //depot/old.lua#2 delete",
        "",
      }

      local data = parse(output)
      assert.equals("42", data.changelist)
      assert.equals(3, #data.files)

      -- Paths must not include #rev.
      for _, f in ipairs(data.files) do
        assert.is_nil(f.path:match("#"), ("file path %q contains #rev"):format(f.path))
      end

      assert.equals("//depot/src/main.lua", data.files[1].path)
      assert.equals("edit", data.files[1].action)
      assert.equals("//depot/src/utils.lua", data.files[2].path)
      assert.equals("add", data.files[2].action)
      assert.equals("//depot/old.lua", data.files[3].path)
      assert.equals("delete", data.files[3].action)
    end)
  end)

  -- ------------------------------------------------------------------
  -- Integration tests: require p4 + p4d
  -- ------------------------------------------------------------------
  describe("tracked_files", function()
    local repo

    before_each(function()
      if not p4_available() then
        pending("p4/p4d not installed")
        return
      end
      repo = create_p4_repo()
    end)

    after_each(function()
      if repo then repo:cleanup() end
    end)

    it("parses p4 opened output without double revision specifiers", test_utils.async_test(function()
      if not p4_available() then pending("p4/p4d not installed") return end

      -- Seed the depot with an initial file.
      repo.write("src/main.lua", 'print("v1")\n')
      repo.p4({ "add", "src/main.lua" })
      repo.p4({ "submit", "-d", "CL 1: add main.lua" })

      -- Open the file for edit so it appears in `p4 opened`.
      repo.p4({ "edit", "src/main.lua" })
      repo.write("src/main.lua", 'print("v2")\n')

      local adapter = repo:adapter()
      local left = P4Rev(RevType.COMMIT, "#head")
      local right = P4Rev(RevType.LOCAL)
      local args = adapter:rev_to_args(left, right)

      local err, files = await(adapter:tracked_files(
        left, right, args, "working",
        { default_layout = Diff2, merge_layout = Diff2 }
      ))

      assert.is_nil(err)
      assert.is_true(#files > 0)

      -- The file path must be a clean depot path without an embedded #rev.
      for _, file in ipairs(files) do
        assert.is_nil(
          file.path:match("#%d+"),
          ("path %q should not contain a revision specifier"):format(file.path)
        )
      end
    end))

    it("parses diff2 -ds output for commit-to-commit diffs", test_utils.async_test(function()
      if not p4_available() then pending("p4/p4d not installed") return end

      -- CL 1: add two files.
      repo.write("src/main.lua", 'print("v1")\n')
      repo.write("src/utils.lua", "local M = {}; return M\n")
      repo.p4({ "add", "src/main.lua", "src/utils.lua" })
      repo.p4({ "submit", "-d", "CL 1: initial" })

      -- CL 2: edit main, delete utils, add new.
      repo.p4({ "edit", "src/main.lua" })
      repo.write("src/main.lua", 'print("v2")\n')
      repo.p4({ "delete", "src/utils.lua" })
      repo.write("src/new.lua", "new\n")
      repo.p4({ "add", "src/new.lua" })
      repo.p4({ "submit", "-d", "CL 2: modify, delete, add" })

      local adapter = repo:adapter()
      local left = P4Rev(RevType.COMMIT, "@1")
      local right = P4Rev(RevType.COMMIT, "@2")
      local args = adapter:rev_to_args(left, right)

      local err, files = await(adapter:tracked_files(
        left, right, args, "working",
        { default_layout = Diff2, merge_layout = Diff2 }
      ))

      assert.is_nil(err)

      -- Build a status lookup keyed by the last component of the depot path.
      local by_name = {}
      for _, file in ipairs(files) do
        local name = file.path:match("[^/]+$")
        by_name[name] = file

        -- No path should contain a #rev suffix.
        assert.is_nil(
          file.path:match("#%d+"),
          ("path %q should not contain a revision specifier"):format(file.path)
        )
      end

      assert.is_not_nil(by_name["main.lua"], "main.lua should appear (modified)")
      assert.equals("M", by_name["main.lua"].status)

      assert.is_not_nil(by_name["new.lua"], "new.lua should appear (added)")
      assert.equals("A", by_name["new.lua"].status)

      assert.is_not_nil(by_name["utils.lua"], "utils.lua should appear (deleted)")
      assert.equals("D", by_name["utils.lua"].status)
    end))

    it("shows file content via get_show_args without errors", test_utils.async_test(function()
      if not p4_available() then pending("p4/p4d not installed") return end

      repo.write("hello.txt", "hello world\n")
      repo.p4({ "add", "hello.txt" })
      repo.p4({ "submit", "-d", "add hello" })

      local adapter = repo:adapter()

      -- Simulate what the plugin does: show file at #head.
      local err, content = await(adapter:show("//depot/hello.txt", P4Rev(RevType.COMMIT, "#head")))

      assert.is_nil(err)
      assert.is_not_nil(content)
      assert.equals("hello world", vim.trim(table.concat(content, "\n")))
    end))
  end)
end)
