--[[
UI tests for diffview.nvim.

Drives a real Neovim through a terminal buffer and asserts on what ends up on
its screen, and on what ends up in the fixture repo.

Usage:
    make ui-test
    nvim -l scripts/ui_test.lua [name-filter]
--]]

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local ui = require("diffview.tests.ui_session")

local filter = _G.arg and _G.arg[1] or nil
local passed, failed = 0, {}
local cur_session

local C = {
  green = "\27[32m",
  red = "\27[31m",
  dim = "\27[2m",
  reset = "\27[0m",
}

---@param msg string
local function fail(msg)
  error(msg, 2)
end

---@param cond any
---@param msg string
local function ok(cond, msg)
  if not cond then fail(msg) end
end

---@param haystack string
---@param needle string
---@param what string
local function contains(haystack, needle, what)
  if not haystack:find(needle) then
    fail(("%s\n--- expected to find: %s\n--- screen:\n%s"):format(what, needle, haystack))
  end
end

---@param haystack string
---@param needle string
---@param what string
local function lacks(haystack, needle, what)
  if haystack:find(needle) then
    fail(("%s\n--- expected NOT to find: %s\n--- screen:\n%s"):format(what, needle, haystack))
  end
end

---@param name string
---@param fn fun(s: diffview.UiSession)
local function test(name, fn)
  if filter and not name:find(filter, 1, true) then return end

  local session = ui.start()
  cur_session = session

  local success, err = pcall(fn, session)

  session:stop()
  cur_session = nil

  if success then
    passed = passed + 1
    io.write(("%s  ok  %s%s\n"):format(C.green, name, C.reset))
  else
    failed[#failed + 1] = { name = name, err = err }
    io.write(("%sNOT OK  %s%s\n%s%s%s\n"):format(C.red, name, C.reset, C.dim, tostring(err), C.reset))
  end

  io.flush()
end

--- Open a diff view and wait for the file panel to be populated.
---@param s diffview.UiSession
local function open_diffview(s)
  s:type(":DiffviewOpen<CR>", 400)
  ok(s:wait_for("Changes %("), "The file panel never listed the working tree changes")
end

---Read a value out of the child.
---
---The value is written to a file rather than printed: a message that doesn't
---fit on the cmdline leaves the child sitting on a hit-enter prompt, which
---swallows the next keystroke the test sends.
---@param s diffview.UiSession
---@param lua_expr string
---@param _key? string # Unused; kept so call sites read as a labelled probe.
---@return string?
local function probe(s, lua_expr, _key)
  local path = s.tmp .. "/probe.txt"
  vim.fn.delete(path)

  s:type((":lua vim.fn.writefile({ tostring(%s) }, %q)<CR>"):format(lua_expr, path), 200)
  vim.wait(4000, function() return vim.fn.filereadable(path) == 1 end, 50)

  return (vim.fn.readfile(path) or {})[1]
end

local VIEW = "require('diffview.lib').get_current_view()"

--------------------------------------------------------------------------------
-- The file panel
--------------------------------------------------------------------------------

test("file panel lists the working tree changes", function(s)
  open_diffview(s)

  local screen = s:flat_screen()
  contains(screen, "Changes %(4%)", "Expected 4 changed files")
  contains(screen, "numbers.txt", "Expected numbers.txt in the panel")
  contains(screen, "init.lua", "Expected src/init.lua in the panel")
  contains(screen, "untracked.txt", "Expected the untracked file in the panel")
end)

test("file panel filters the file list", function(s)
  open_diffview(s)

  s:type("/", 300)
  s:type("numbers<CR>", 500)

  local screen = s:flat_screen()
  contains(screen, "Filter: numbers", "The active filter should be shown in the panel")
  contains(screen, "numbers.txt", "The matching file should still be listed")
  lacks(screen, "README.md", "A file that doesn't match the filter should be hidden")

  -- An empty filter clears it again.
  s:type("/", 300)
  s:type("<C-u><CR>", 500)

  screen = s:flat_screen()
  lacks(screen, "Filter:", "The filter should have been cleared")
  contains(screen, "README.md", "Every file should be listed again")
end)

test("file panel marks the file that is open in the view", function(s)
  open_diffview(s)

  local MARK = ("(function() local m = vim.api.nvim_buf_get_extmarks(%s.panel.bufid, "
    .. "vim.api.nvim_create_namespace('diffview_panel_selected'), 0, -1, { details = true }) "
    .. "if #m == 0 then return 'none' end return m[1][2] + 1 .. ':' .. m[1][4].line_hl_group end)()")
    :format(VIEW)
  local CURSOR = ("vim.api.nvim_win_get_cursor(%s.panel.winid)[1]"):format(VIEW)

  s:type("<Tab>", 1000)

  local mark = probe(s, MARK, "MARK")
  local line = tonumber(probe(s, CURSOR, "CURSOR"))

  ok(mark == line .. ":DiffviewFilePanelSelectedLine",
    ("Expected the open entry to be marked on line %s, got %s"):format(line, mark))

  -- Browsing the panel must not move the mark: it tracks what's open, not the
  -- cursor.
  s:type("j", 400)
  s:type("j", 400)

  ok(probe(s, MARK, "MARK") == mark, "The mark should stay on the file that is open")
  ok(tonumber(probe(s, CURSOR, "CURSOR")) ~= line, "The cursor should have moved")

  -- Opening the entry under the cursor moves it.
  s:type("<CR>", 1200)
  local moved = probe(s, MARK, "MARK")

  ok(moved ~= mark, "The mark should follow the newly opened entry")
  contains(moved or "", "DiffviewFilePanelSelectedLine", "The mark should keep its highlight group")
end)

test("file panel copies the path of an entry", function(s)
  open_diffview(s)

  -- Move to the first file entry, copy its path, and paste it into a buffer we
  -- can read off the screen.
  s:type("<Tab>", 400)
  s:type("gy", 300)
  contains(s:flat_screen(), "Copied path", "Expected a confirmation for the copied path")
end)

--------------------------------------------------------------------------------
-- Hunk staging
--------------------------------------------------------------------------------

test("stages the hunk under the cursor", function(s)
  open_diffview(s)

  -- Open numbers.txt and move into the diff.
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 600)
  ok(s:wait_for("line 2 CHANGED"), "The diff for numbers.txt never opened")

  -- Focus the right hand side of the diff and go to the first change.
  s:type("<C-w>l", 200)
  s:type("]c", 300)
  s:type("\\hs", 800)

  ok(s:wait_for("Staged changes"), "The panel never got a 'Staged changes' section")

  local staged = s:git("diff", "--cached", "--no-color", "--", "numbers.txt")
  local added = table.concat(staged, "\n")

  contains(added, "%+line 2 CHANGED", "The first hunk should have been staged")
  lacks(added, "%+line 18 CHANGED", "The second hunk should NOT have been staged")

  -- The second hunk is still in the working tree.
  contains(
    table.concat(s:git("diff", "--no-color", "--", "numbers.txt"), "\n"),
    "%+line 18 CHANGED",
    "The second hunk should still be unstaged"
  )
end)

test("stages a visual selection", function(s)
  open_diffview(s)

  s:type("/numbers<CR>", 400)
  s:type("<CR>", 600)
  ok(s:wait_for("line 2 CHANGED"), "The diff for numbers.txt never opened")

  s:type("<C-w>l", 200)
  -- Select the second hunk only: jump to it, then select the single line.
  s:type("]c", 300)
  s:type("]c", 300)
  s:type("V", 200)
  s:type("\\hs", 800)

  ok(s:wait_for("Staged changes"), "The panel never got a 'Staged changes' section")

  local staged = table.concat(s:git("diff", "--cached", "--no-color", "--", "numbers.txt"), "\n")
  contains(staged, "%+line 18 CHANGED", "The selected line should have been staged")
  lacks(staged, "%+line 2 CHANGED", "The unselected hunk should NOT have been staged")
end)

test("unstages the hunk under the cursor", function(s)
  s:git("add", "numbers.txt")

  open_diffview(s)
  ok(s:wait_for("Staged changes"), "The staged file should be listed")

  -- Open the staged entry: it's the last file in the panel.
  s:type("]F", 800)
  ok(s:wait_for("line 2 CHANGED"), "The staged diff never opened")

  s:type("<C-w>l", 200)
  s:type("]c", 300)
  s:type("\\hu", 800)

  ok(vim.wait(5000, function()
    local staged = table.concat(s:git("diff", "--cached", "--no-color", "--", "numbers.txt"), "\n")
    return staged:find("%+line 2 CHANGED") == nil
  end, 100), "The hunk was never unstaged")

  -- The change is still in the working tree.
  contains(
    table.concat(s:read("numbers.txt"), "\n"),
    "line 2 CHANGED",
    "Unstaging must not touch the working tree"
  )
end)

test("restores the hunk under the cursor", function(s)
  open_diffview(s)

  s:type("/numbers<CR>", 400)
  s:type("<CR>", 600)
  ok(s:wait_for("line 2 CHANGED"), "The diff for numbers.txt never opened")

  s:type("<C-w>l", 200)
  s:type("]c", 300)
  s:type("\\hr", 800)

  ok(vim.wait(5000, function()
    return s:read("numbers.txt")[2] == "line 2"
  end, 100), "The first hunk was never restored in the working tree")

  -- Only the first hunk was restored.
  ok(s:read("numbers.txt")[18] == "line 18 CHANGED", "The second hunk should be untouched")
end)

test("stages a hunk of an untracked file", function(s)
  open_diffview(s)

  s:type("/untracked<CR>", 400)
  s:type("<CR>", 800)
  ok(s:wait_for("brand new"), "The diff for the untracked file never opened")

  s:type("<C-w>l", 200)
  s:type("\\hs", 1000)

  ok(vim.wait(5000, function()
    return table.concat(s:git("diff", "--cached", "--no-color"), "\n"):find("%+brand new") ~= nil
  end, 100), "The content of the untracked file was never staged. Screen:\n" .. s:screen())
end)

test("reports when there is no hunk under the cursor", function(s)
  open_diffview(s)

  s:type("/numbers<CR>", 400)
  s:type("<CR>", 600)
  ok(s:wait_for("line 2 CHANGED"), "The diff for numbers.txt never opened")

  -- Line 10 of numbers.txt lies between the two hunks.
  s:type("<C-w>l", 200)
  s:type("10G", 200)
  s:type("\\hs", 700)

  contains(s:flat_screen(), "no hunk under the cursor", "Expected a message about the missing hunk")
end)

test("refuses to stage hunks from the file panel", function(s)
  open_diffview(s)

  -- The hunk actions aren't mapped in the file panel by default, but they are
  -- reachable through the API.
  s:type(":lua require('diffview.actions').stage_hunk()<CR>", 700)
  contains(s:flat_screen(), "must be in one of the diff windows", "Expected an error about the cursor position")
end)

test("refuses to stage hunks outside of a diff of the index", function(s)
  s:type(":DiffviewOpen HEAD~1<CR>", 1500)
  s:type("<Tab>", 600)
  s:type("<C-w>l", 200)
  s:type("\\hs", 600)

  contains(
    s:flat_screen(),
    "index and the working tree",
    "Expected an error explaining that hunks can't be staged from this diff"
  )
end)

--------------------------------------------------------------------------------
-- Navigation and display options
--------------------------------------------------------------------------------

test("jumps to the changes across files", function(s)
  open_diffview(s)

  s:type("[F", 800)
  s:type("<C-w>l", 200)

  -- Walk forward through every change: this has to roll over into the next
  -- file rather than stopping at the end of the current one.
  local seen = {}

  for _ = 1, 6 do
    s:type("]c", 350)
    local screen = s:flat_screen()
    for _, name in ipairs({ "numbers.txt", "init.lua", "README.md", "untracked.txt" }) do
      if screen:find(name) then seen[name] = true end
    end
  end

  ok(seen["numbers.txt"], "Never visited numbers.txt")
  ok(vim.tbl_count(seen) > 1, "The change navigation never rolled over into another file")
end)

test("reports when there are no more changes", function(s)
  -- A view with a single file: there is nothing to roll over into.
  s:type(":DiffviewOpen -uno -- numbers.txt<CR>", 600)
  ok(s:wait_for("Changes %(1%)"), "Expected a view with a single file")

  s:type("<Tab>", 900)
  s:type("<C-w>l", 300)
  s:type("G", 300)

  for _ = 1, 3 do s:type("]c", 500) end

  contains(s:flat_screen(), "no more changes", "Expected a message rather than an error. Screen:\n" .. s:screen())
  lacks(s:flat_screen(), "E5108", "Walking past the last change should not raise an error")
end)

test("toggles the display options", function(s)
  open_diffview(s)

  s:type("\\dw", 400)
  contains(s:flat_screen(), "Whitespace changes are now ignored", "Expected the whitespace toggle to report its state")

  s:type("\\dw", 400)
  contains(s:flat_screen(), "Whitespace changes are now shown", "Expected the whitespace toggle to report its state")

  s:type("\\du", 400)
  contains(s:flat_screen(), "Unchanged regions are now shown", "Expected the fold toggle to report its state")

  s:type("\\du", 400)
  contains(s:flat_screen(), "Unchanged regions are now hidden", "Expected the fold toggle to report its state")
end)

test("takes over 'diffopt' while the view is open", function(s)
  s:type(":set diffopt=internal,filler,closeoff<CR>", 300)

  open_diffview(s)
  s:type(":set diffopt?<CR>", 400)

  local screen = s:flat_screen()
  contains(screen, "algorithm:histogram", "The configured diff algorithm should be in effect")
  contains(screen, "linematch:60", "linematch should be in effect")
  contains(screen, "closeoff", "The user's own flags should be kept")

  s:type(":DiffviewClose<CR>", 600)
  s:type(":set diffopt?<CR>", 400)

  screen = s:flat_screen()
  lacks(screen, "linematch", "'diffopt' should be restored when the view is closed")
  contains(screen, "closeoff", "'diffopt' should be restored when the view is closed")
end)

--------------------------------------------------------------------------------
-- Layouts and panels
--------------------------------------------------------------------------------


test("cycles between the side-by-side and stacked layouts", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)

  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "diff2_horizontal",
    "Expected the default side-by-side layout. Screen:\n" .. s:screen())

  s:type("g<C-x>", 1000)
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "diff2_vertical",
    "'g<C-x>' should switch to the stacked layout. Screen:\n" .. s:screen())

  s:type("g<C-x>", 1000)
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "'g<C-x>' should continue into the inline layout. Screen:\n" .. s:screen())

  s:type("g<C-x>", 1000)
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "diff2_horizontal",
    "'g<C-x>' should cycle back to the side-by-side layout. Screen:\n" .. s:screen())
end)

test("keeps the display options across a layout cycle", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)

  -- Unfold the unchanged regions, then switch layout.
  s:type("\\du", 500)
  s:type("g<C-x>", 1000)

  ok(probe(s, "vim.wo[" .. VIEW .. ".cur_layout:get_main_win().id].foldlevel", "FOLDLEVEL") == "99",
    "The unchanged regions should still be shown after a layout cycle. Screen:\n" .. s:screen())

  -- And it also survives switching to another file.
  s:type("<Tab>", 900)
  ok(probe(s, "vim.wo[" .. VIEW .. ".cur_layout:get_main_win().id].foldlevel", "FOLDLEVEL") == "99",
    "The unchanged regions should still be shown in the next file. Screen:\n" .. s:screen())
end)

test("stages a hunk in the stacked layout", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("g<C-x>", 1000)

  -- In the stacked layout the working tree version is the lower window.
  s:type("<C-w>b", 300)
  s:type("gg", 200)
  s:type("]c", 400)
  s:type("\\hs", 1000)

  ok(vim.wait(5000, function()
    return table.concat(s:git("diff", "--cached", "--no-color"), "\n"):find("%+line 2 CHANGED") ~= nil
  end, 100), "Staging should work the same in the stacked layout. Screen:\n" .. s:screen())
end)

test("opens with the stacked layout when configured", function(s)
  s:type(":lua require('diffview').setup({ view = { default = { layout = 'diff2_vertical' } } })<CR>", 600)
  open_diffview(s)
  s:type("<Tab>", 800)

  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "diff2_vertical",
    "The configured layout should be used. Screen:\n" .. s:screen())
end)

test("focuses a file that is already open instead of splitting", function(s)
  -- A developer's normal state: the file is already open in another tabpage.
  s:type(":edit numbers.txt<CR>", 600)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("<C-w>l", 300)
  s:type("gf", 1200)

  ok(probe(s, "#vim.api.nvim_tabpage_list_wins(0)", "WINS") == "1",
    "'gf' should reuse the window that already has the file, not split. Screen:\n" .. s:screen())
  ok(probe(s, "vim.fn.expand('%:t')", "BUF") == "numbers.txt",
    "'gf' should land on the file. Screen:\n" .. s:screen())
end)

test("toggles and focuses the file panel", function(s)
  open_diffview(s)

  s:type("\\b", 600)
  ok(s:wait_until_gone("Changes %("), "'<leader>b' should hide the file panel. Screen:\n" .. s:screen())

  s:type("\\b", 600)
  ok(s:wait_for("Changes %("), "'<leader>b' should bring the file panel back. Screen:\n" .. s:screen())

  -- Focus follows the file panel.
  s:type("<C-w>l", 300)
  s:type("\\e", 500)
  ok(probe(s, "vim.api.nvim_get_current_win() == " .. VIEW .. ".panel.winid", "FOCUSED") == "true",
    "'<leader>e' should bring focus to the file panel. Screen:\n" .. s:screen())
end)

test("stages a hunk with the file panel hidden", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("\\b", 600)

  s:type("gg", 200)
  s:type("]c", 400)
  s:type("\\hs", 1000)

  ok(vim.wait(5000, function()
    return table.concat(s:git("diff", "--cached", "--no-color"), "\n"):find("%+line 2 CHANGED") ~= nil
  end, 100), "Staging should work with the panel closed. Screen:\n" .. s:screen())
end)

--------------------------------------------------------------------------------
-- The inline (unified) diff
--------------------------------------------------------------------------------

---@param s diffview.UiSession
local function open_inline(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("\\di", 1500)

  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "'gi' should switch to the inline diff. Screen:\n" .. s:screen())
end

test("toggles the inline diff on and off", function(s)
  open_inline(s)

  -- Both versions of the changed line are in the same window.
  local screen = s:flat_screen()
  contains(screen, "line 2 CHANGED", "The new version should be shown")
  contains(screen, "%- line 2", "The old version should be shown right above it")

  s:type("\\di", 1500)
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "diff2_horizontal",
    "'gi' should switch back to the side-by-side diff. Screen:\n" .. s:screen())
end)

test("highlights the changes in the inline diff", function(s)
  open_inline(s)

  local expr = ("#vim.api.nvim_buf_get_extmarks(%s.cur_layout:get_main_win().file.bufnr, "
    .. "vim.api.nvim_create_namespace('diffview_unified'), 0, -1, {})"):format(VIEW)

  local count = tonumber(probe(s, expr, "MARKS")) or 0
  ok(count >= 4, "Expected the added and removed lines to be highlighted, got " .. count .. " marks")
end)

test("navigates the changes in the inline diff", function(s)
  open_inline(s)

  s:type("gg", 300)
  s:type("]c", 500)
  local first = tonumber(probe(s, "vim.fn.line('.')", "LNUM"))

  s:type("]c", 500)
  local second = tonumber(probe(s, "vim.fn.line('.')", "LNUM"))

  ok(first and second and second > first,
    ("']c' should walk the changes (got %s then %s). Screen:\n%s"):format(first, second, s:screen()))

  s:type("[c", 500)
  ok(tonumber(probe(s, "vim.fn.line('.')", "LNUM")) == first,
    "'[c' should walk back. Screen:\n" .. s:screen())
end)

test("stages a hunk from the inline diff", function(s)
  open_inline(s)

  s:type("gg", 300)
  s:type("]c", 500)
  s:type("\\hs", 1500)

  ok(vim.wait(5000, function()
    return table.concat(s:git("diff", "--cached", "--no-color"), "\n"):find("%+line 2 CHANGED") ~= nil
  end, 100), "The hunk under the cursor should have been staged. Screen:\n" .. s:screen())

  -- The other hunk is untouched, and the view is still inline.
  lacks(table.concat(s:git("diff", "--cached", "--no-color"), "\n"), "%+line 18 CHANGED",
    "Only the hunk under the cursor should have been staged")
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "The view should still be inline after staging")
end)

test("stages a selection from the inline diff", function(s)
  open_inline(s)

  -- Select the second change, which shows as a removed and an added line.
  s:type("G", 300)
  s:type("[c", 500)
  s:type("Vj", 300)
  s:type("\\hs", 1500)

  ok(vim.wait(5000, function()
    return table.concat(s:git("diff", "--cached", "--no-color"), "\n"):find("%+line 18 CHANGED") ~= nil
  end, 100), "The selected change should have been staged. Screen:\n" .. s:screen())

  lacks(table.concat(s:git("diff", "--cached", "--no-color"), "\n"), "%+line 2 CHANGED",
    "The unselected change should NOT have been staged")
end)

test("keeps the inline diff when switching files", function(s)
  open_inline(s)

  -- Clear the filter so there's another file to switch to.
  s:type("<leader>e", 400)
  s:type("/", 300)
  s:type("<C-u><CR>", 600)
  s:type("<Tab>", 1500)

  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "The next file should open inline too. Screen:\n" .. s:screen())
end)

test("cycles through the inline layout", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("<C-w>l", 300)

  local seen = {}

  for _ = 1, 3 do
    s:type("g<C-x>", 1500)
    seen[#seen + 1] = probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT")
  end

  ok(vim.tbl_contains(seen, "diff2_vertical"), "Expected the stacked layout in the cycle: " .. vim.inspect(seen))
  ok(vim.tbl_contains(seen, "unified"), "Expected the inline layout in the cycle: " .. vim.inspect(seen))
  ok(seen[3] == "diff2_horizontal", "The cycle should return to the side-by-side layout: " .. vim.inspect(seen))
end)

test("opens inline when configured", function(s)
  s:type(":lua require('diffview').setup({ view = { default = { layout = 'unified' } } })<CR>", 700)
  open_diffview(s)
  s:type("<Tab>", 1200)

  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "The configured inline layout should be used. Screen:\n" .. s:screen())
end)

--------------------------------------------------------------------------------
-- Editing
--------------------------------------------------------------------------------

test("edits the working tree from the diff", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)

  -- Panel | index | working tree: two windows right of the panel.
  s:type("<C-w>l<C-w>l", 400)
  ok((probe(s, "vim.api.nvim_buf_get_name(0)", "BUF") or ""):find("diffview://") == nil,
    "Expected to be in the working tree window")

  s:type("gg", 200)
  s:type("A EDITED<Esc>", 500)
  s:type(":w<CR>", 1200)

  ok(vim.wait(5000, function() return s:read("numbers.txt")[1] == "line 1 EDITED" end, 100),
    "Writing the working tree side should save the file. Screen:\n" .. s:screen())
end)

test("edits the index from the diff", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)

  -- The window right of the panel is the index side.
  s:type("<C-w>l", 400)
  ok((probe(s, "vim.api.nvim_buf_get_name(0)", "BUF") or ""):find(":0:") ~= nil,
    "Expected to be in the index window")

  s:type("gg", 200)
  s:type("A STAGED<Esc>", 500)
  s:type(":w<CR>", 1500)

  ok(vim.wait(5000, function()
    return (s:git("show", ":0:numbers.txt")[1] or "") == "line 1 STAGED"
  end, 100), "Writing the index side should stage the content. Screen:\n" .. s:screen())

  -- The working tree is untouched.
  ok(s:read("numbers.txt")[1] == "line 1", "Staging must not touch the working tree")
end)

test("edits the working tree from the inline diff", function(s)
  open_diffview(s)
  s:type("/numbers<CR>", 400)
  s:type("<CR>", 700)
  s:type("\\di", 1800)

  -- Put the cursor on the added line and change it.
  s:type("gg", 200)
  s:type("]c", 500)
  s:type("j", 200)
  s:type("A EDITED<Esc>", 500)
  s:type(":w<CR>", 2000)

  ok(vim.wait(5000, function() return s:read("numbers.txt")[2] == "line 2 CHANGED EDITED" end, 100),
    "Writing the inline diff should save the file. Screen:\n" .. s:screen())

  -- The removed line is not part of the file, and the rest is intact.
  local content = s:read("numbers.txt")
  ok(#content == 20, "The file should still have 20 lines, got " .. #content)
  ok(content[1] == "line 1", "The unchanged lines should be untouched")
  ok(content[18] == "line 18 CHANGED", "The other change should be untouched")

  -- The view stays usable, and re-renders against the new content.
  ok(probe(s, VIEW .. ".cur_layout.class.name", "LAYOUT") == "unified",
    "The view should still be inline after writing")
  ok(probe(s, "vim.bo.modified", "MODIFIED") == "false", "The buffer should no longer be modified")
end)

test("edits the index from the inline diff", function(s)
  s:git("add", "numbers.txt")

  open_diffview(s)
  ok(s:wait_for("Staged changes"), "The staged file should be listed")

  s:type("]F", 1000)
  s:type("\\di", 1800)

  s:type("gg", 200)
  s:type("]c", 500)
  s:type("j", 200)
  s:type("A STAGED<Esc>", 500)
  s:type(":w<CR>", 2000)

  ok(vim.wait(5000, function()
    return (s:git("show", ":0:numbers.txt")[2] or "") == "line 2 CHANGED STAGED"
  end, 100), "Writing the inline diff of a staged entry should stage it. Screen:\n" .. s:screen())

  -- The working tree keeps what it had.
  ok(s:read("numbers.txt")[2] == "line 2 CHANGED", "The working tree should be untouched")
end)

test("keeps historical diffs read-only", function(s)
  s:type(":DiffviewOpen HEAD~1<CR>", 1200)
  s:type("<Tab>", 1200)

  -- The window right of the panel shows a commit: it must not be writable.
  s:type("<C-w>l", 400)
  ok((probe(s, "vim.api.nvim_buf_get_name(0)", "BUF") or ""):find("diffview://") ~= nil,
    "Expected to be in the commit window")
  ok(probe(s, "vim.bo.modifiable", "MODIFIABLE") == "false",
    "A commit buffer should not be modifiable. Screen:\n" .. s:screen())
  ok(probe(s, "vim.bo.buftype", "BUFTYPE") == "nowrite",
    "A commit buffer should not be writable. Screen:\n" .. s:screen())
end)

--------------------------------------------------------------------------------
-- Committing
--------------------------------------------------------------------------------

test("commits the staged changes", function(s)
  s:git("add", "numbers.txt")

  open_diffview(s)
  ok(s:wait_for("Staged changes"), "The staged file should be listed")

  s:type("cc", 800)
  ok(s:wait_for("Write the commit message above"), "The commit editor never opened")

  s:type("A hunk staging works", 300)
  s:type("<C-c><C-c>", 1200)

  ok(vim.wait(5000, function()
    return (s:git("log", "-1", "--pretty=%s")[1] or ""):find("hunk staging works") ~= nil
  end, 100), "The commit was never created. Screen:\n" .. s:screen())

  -- Nothing staged is left over.
  local _, code = s:git("diff", "--cached", "--quiet")
  ok(code == 0, "The index should be clean after committing")
end)

test("refuses to commit without staged changes", function(s)
  open_diffview(s)

  s:type("cc", 800)
  contains(s:flat_screen(), "no staged changes", "Expected an error about the empty index")
end)

test("aborts an empty commit message", function(s)
  s:git("add", "numbers.txt")

  open_diffview(s)
  ok(s:wait_for("Staged changes"), "The staged file should be listed")

  s:type("cc", 800)
  ok(s:wait_for("Write the commit message above"), "The commit editor never opened")

  s:type("<Esc>", 200)
  s:type("<C-c><C-c>", 600)

  contains(s:flat_screen(), "empty commit message", "Expected the empty message to be rejected")
end)

--------------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(passed, #failed))

if cur_session then cur_session:stop() end

if #failed > 0 then
  for _, f in ipairs(failed) do
    io.write(("%sFAILED: %s%s\n"):format(C.red, f.name, C.reset))
  end
  os.exit(1)
end

os.exit(0)
