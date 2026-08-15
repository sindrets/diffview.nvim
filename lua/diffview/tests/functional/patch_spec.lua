local helpers = require("diffview.tests.helpers")
local patch = require("diffview.vcs.patch")

local eq = helpers.eq

local PATCH = {
  "diff --git a/file.txt b/file.txt",
  "index 1234567..89abcde 100644",
  "--- a/file.txt",
  "+++ b/file.txt",
  "@@ -1,5 +1,5 @@",
  " one",
  "-two",
  "+TWO",
  " three",
  " four",
  " five",
  "@@ -10,4 +10,5 @@",
  " ten",
  "+eleven",
  " twelve",
  " thirteen",
  " fourteen",
}

---@param dir string
---@param ... string
---@return string[] stdout
---@return integer code
local function git(dir, ...)
  local out = vim.fn.systemlist(vim.list_extend({ "git", "-C", dir }, { ... }))
  return out, vim.v.shell_error
end

---Create a repo with a committed 20 line file.
---@return string toplevel
local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  git(dir, "init", "-q")
  git(dir, "config", "user.email", "test@diffview.nvim")
  git(dir, "config", "user.name", "Diffview Test")
  git(dir, "config", "commit.gpgsign", "false")

  local lines = {}
  for i = 1, 20 do
    lines[i] = "line " .. i
  end

  vim.fn.writefile(lines, dir .. "/file.txt")
  git(dir, "add", "file.txt")
  git(dir, "commit", "-qm", "init")

  return dir
end

---@param dir string
---@param cached boolean
---@return patch.File?
local function get_patch(dir, cached)
  local args = { "diff", "--no-color", "--unified=3" }
  if cached then table.insert(args, "--cached") end
  vim.list_extend(args, { "--", "file.txt" })

  return patch.parse((git(dir, unpack(args))))[1]
end

---The content of every added line in a diff.
---@param dir string
---@param cached boolean
---@return string[]
local function added_lines(dir, cached)
  local args = { "diff", "--no-color" }
  if cached then table.insert(args, "--cached") end

  return vim.tbl_map(
    function(line) return line:sub(2) end,
    vim.tbl_filter(function(line)
      return line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++"
    end, (git(dir, unpack(args))))
  )
end

---@param dir string
---@param p string
---@param ... string
---@return integer code
local function apply(dir, p, ...)
  local args = vim.list_extend({ "git", "-C", dir, "apply", "--whitespace=nowarn" }, { ... })
  vim.fn.system(args, p)
  return vim.v.shell_error
end

describe("diffview.vcs.patch", function()
  describe("parse", function()
    local files = patch.parse(PATCH)

    it("finds every file section", function()
      eq(1, #files)
      eq("file.txt", files[1].path_old)
      eq("file.txt", files[1].path_new)
      eq(4, #files[1].header)
    end)

    it("finds every hunk", function()
      eq(2, #files[1].hunks)
    end)

    it("reads the hunk headers", function()
      local hunks = files[1].hunks

      eq({ 1, 5, 1, 5 }, {
        hunks[1].old_row,
        hunks[1].old_size,
        hunks[1].new_row,
        hunks[1].new_size,
      })
      eq({ 10, 4, 10, 5 }, {
        hunks[2].old_row,
        hunks[2].old_size,
        hunks[2].new_row,
        hunks[2].new_size,
      })
    end)

    it("keeps the raw hunk lines", function()
      eq({ " one", "-two", "+TWO", " three", " four", " five" }, files[1].hunks[1].lines)
    end)

    it("counts the changes", function()
      local additions, deletions = patch.count_changes(files[1].hunks)
      eq(2, additions)
      eq(1, deletions)
    end)
  end)

  describe("hunk lookup", function()
    local file = patch.parse(PATCH)[1]

    it("finds the hunk at a line", function()
      eq(file.hunks[1], patch.hunk_at(file, 2, "old"))
      eq(file.hunks[1], patch.hunk_at(file, 5, "new"))
      eq(file.hunks[2], patch.hunk_at(file, 11, "new"))
      eq(nil, patch.hunk_at(file, 8, "new"))
    end)

    it("finds the hunks intersecting a range", function()
      eq(1, #patch.hunks_in_range(file, 1, 3, "new"))
      eq(2, #patch.hunks_in_range(file, 1, 20, "new"))
      eq(0, #patch.hunks_in_range(file, 7, 8, "new"))
    end)

    it("finds the adjacent hunk", function()
      eq(file.hunks[2], patch.adjacent_hunk(file, 5, "new", 1))
      eq(file.hunks[1], patch.adjacent_hunk(file, 11, "new", -1))
      eq(nil, patch.adjacent_hunk(file, 14, "new", 1))
    end)
  end)

  describe("build", function()
    it("reproduces the patch it parsed", function()
      local file = patch.parse(PATCH)[1]
      eq(table.concat(PATCH, "\n") .. "\n", patch.build(file, file.hunks))
    end)

    it("offsets the target rows when hunks are left out", function()
      local file = patch.parse(PATCH)[1]
      local out = vim.split(patch.build(file, { file.hunks[2] }), "\n")

      -- The first hunk isn't part of the patch, so the second hunk applies at
      -- the same offset on both sides.
      eq("@@ -10,4 +10,5 @@", out[5])
    end)
  end)

  describe("select_lines", function()
    local file = patch.parse(PATCH)[1]

    -- A hunk with two separate modifications, so that one can be picked while
    -- the other is left alone.
    local multi = patch.parse({
      "diff --git a/file.txt b/file.txt",
      "--- a/file.txt",
      "+++ b/file.txt",
      "@@ -1,5 +1,5 @@",
      " one",
      "-two",
      "+TWO",
      " three",
      "-four",
      "+FOUR",
      " five",
    })[1].hunks[1]

    it("takes a changed line together with the line it replaces", function()
      -- Selecting the addition on the new side.
      local hunk = patch.select_lines(multi, 2, 2, "new", false)

      eq({ " one", "-two", "+TWO", " three", " four", " five" }, hunk.lines)
      eq(5, hunk.old_size)
      eq(5, hunk.new_size)

      -- Selecting the deletion on the old side gives the same patch.
      eq(hunk.lines, patch.select_lines(multi, 2, 2, "old", false).lines)
    end)

    it("demotes the unselected changes in a reverse patch", function()
      local hunk = patch.select_lines(multi, 2, 2, "new", true)

      -- 'four' is left as it is in the working tree: 'FOUR'.
      eq({ " one", "-two", "+TWO", " three", " FOUR", " five" }, hunk.lines)
      eq(5, hunk.old_size)
      eq(5, hunk.new_size)
    end)

    it("drops unselected additions in a forward patch", function()
      local hunk = patch.select_lines(file.hunks[2], 11, 11, "new", false)
      eq({ " ten", "+eleven", " twelve", " thirteen", " fourteen" }, hunk.lines)

      -- Nothing selected: no patch at all.
      eq(nil, patch.select_lines(file.hunks[2], 14, 14, "new", false))
    end)

    it("keeps a pure addition out of a reverse patch when unselected", function()
      local hunk = patch.select_lines(file.hunks[2], 13, 13, "new", true)
      eq(nil, hunk)
    end)

    it("pairs a surplus deletion with the last addition", function()
      -- Three lines replaced by one.
      local hunk = patch.parse({
        "diff --git a/file.txt b/file.txt",
        "--- a/file.txt",
        "+++ b/file.txt",
        "@@ -1,5 +1,3 @@",
        " one",
        "-two",
        "-three",
        "-four",
        "+TWO",
        " five",
      })[1].hunks[1]

      local sel = patch.select_lines(hunk, 2, 2, "new", false)

      eq({ " one", "-two", "+TWO", "-three", "-four", " five" }, sel.lines)
      eq(5, sel.old_size)
      eq(3, sel.new_size)
    end)
  end)

  describe("git round trip", function()
    it("stages a single hunk", function()
      local dir = make_repo()
      local lines = vim.fn.readfile(dir .. "/file.txt")
      lines[2] = "line 2 changed"
      lines[18] = "line 18 changed"
      vim.fn.writefile(lines, dir .. "/file.txt")

      local file = get_patch(dir, false)
      eq(2, #file.hunks)

      eq(0, apply(dir, patch.build(file, { file.hunks[1] }), "--cached"))

      -- Only the first change was staged.
      eq({ "line 2 changed" }, added_lines(dir, true))

      -- The second change is still only in the working tree.
      local unstaged = get_patch(dir, false)
      eq(1, #unstaged.hunks)
      eq(0, apply(dir, patch.build(unstaged, unstaged.hunks), "--cached"))
      eq(0, #(get_patch(dir, false) or { hunks = {} }).hunks)

      vim.fn.delete(dir, "rf")
    end)

    it("stages only the selected lines of a hunk", function()
      local dir = make_repo()
      local lines = vim.fn.readfile(dir .. "/file.txt")
      lines[2] = "line 2 changed"
      lines[3] = "line 3 changed"
      vim.fn.writefile(lines, dir .. "/file.txt")

      local file = get_patch(dir, false)
      eq(1, #file.hunks)

      -- Stage line 2 only.
      local selection = patch.select_lines(file.hunks[1], 2, 2, "new", false)
      eq(0, apply(dir, patch.build(file, { selection }), "--cached"))

      local staged = added_lines(dir, true)

      eq({ "line 2 changed" }, staged)

      -- What's left unstaged is the other line.
      local rest = added_lines(dir, false)

      eq({ "line 3 changed" }, rest)

      vim.fn.delete(dir, "rf")
    end)

    it("unstages the selected lines of a hunk", function()
      local dir = make_repo()
      local lines = vim.fn.readfile(dir .. "/file.txt")
      lines[2] = "line 2 changed"
      lines[3] = "line 3 changed"
      vim.fn.writefile(lines, dir .. "/file.txt")
      git(dir, "add", "file.txt")

      local file = get_patch(dir, true)
      eq(1, #file.hunks)

      -- Unstage line 2 only: applied in reverse to the index.
      local selection = patch.select_lines(file.hunks[1], 2, 2, "new", true)
      eq(0, apply(dir, patch.build(file, { selection }, true), "--cached", "--reverse"))

      local staged = added_lines(dir, true)

      eq({ "line 3 changed" }, staged)

      -- The working tree still has both changes.
      eq("line 2 changed", vim.fn.readfile(dir .. "/file.txt")[2])
      eq("line 3 changed", vim.fn.readfile(dir .. "/file.txt")[3])

      vim.fn.delete(dir, "rf")
    end)

    it("restores the selected lines in the working tree", function()
      local dir = make_repo()
      local lines = vim.fn.readfile(dir .. "/file.txt")
      lines[2] = "line 2 changed"
      lines[3] = "line 3 changed"
      vim.fn.writefile(lines, dir .. "/file.txt")

      local file = get_patch(dir, false)
      local selection = patch.select_lines(file.hunks[1], 3, 3, "new", true)
      eq(0, apply(dir, patch.build(file, { selection }, true), "--reverse"))

      lines = vim.fn.readfile(dir .. "/file.txt")
      eq("line 2 changed", lines[2])
      eq("line 3", lines[3])

      vim.fn.delete(dir, "rf")
    end)

    it("stages an added line at the start of a file", function()
      local dir = make_repo()
      local lines = vim.fn.readfile(dir .. "/file.txt")
      table.insert(lines, 1, "new first line")
      vim.fn.writefile(lines, dir .. "/file.txt")

      local file = get_patch(dir, false)
      local selection = patch.select_lines(file.hunks[1], 1, 1, "new", false)
      eq(0, apply(dir, patch.build(file, { selection }), "--cached"))
      eq(0, #(get_patch(dir, false) or { hunks = {} }).hunks)

      vim.fn.delete(dir, "rf")
    end)
  end)
end)
