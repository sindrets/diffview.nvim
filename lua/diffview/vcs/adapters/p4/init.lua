local AsyncListStream = require("diffview.stream").AsyncListStream
local p4_commit = require("diffview.vcs.adapters.p4.commit")
local Commit = p4_commit.P4Commit
local parse_describe_output = p4_commit.parse_describe_output
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileEntry = require("diffview.scene.file_entry").FileEntry
local FlagOption = require("diffview.vcs.flag_option").FlagOption
local P4Rev = require("diffview.vcs.adapters.p4.rev").P4Rev
local Job = require("diffview.job").Job
local JobStatus = require("diffview.vcs.utils").JobStatus
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local MultiJob = require("diffview.multi_job").MultiJob
local RevType = require("diffview.vcs.rev").RevType
local VCSAdapter = require("diffview.vcs.adapter").VCSAdapter
local arg_parser = require("diffview.arg_parser")
local async = require("diffview.async")
local config = require("diffview.config")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local vcs_utils = require("diffview.vcs.utils")

local api = vim.api
local await, pawait = async.await, async.pawait
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") ---@type PathLib
local uv = vim.loop

local M = {}

---@class P4Adapter : VCSAdapter
---@operator call : P4Adapter
local P4Adapter = oop.create_class("P4Adapter", VCSAdapter)

P4Adapter.Rev = P4Rev
P4Adapter.config_key = "p4" -- Key for config table
P4Adapter.bootstrap = {
  done = false,
  ok = false,
  version = {}, -- P4 version parsing can be complex, skip detailed check for now
  target_version = {}, -- Not strictly enforced currently
}

function P4Adapter.run_bootstrap()
  local p4_cmd = config.get_config().p4_cmd -- Use p4_cmd from config
  local bs = P4Adapter.bootstrap
  bs.done = true

  local function err(msg)
    if msg then
      bs.err = msg
      logger:error("[P4Adapter] " .. bs.err)
    end
  end

  if vim.fn.executable(p4_cmd[1]) ~= 1 then
    return err(fmt("Configured `p4_cmd` is not executable: '%s'", p4_cmd[1]))
  end

  -- Check if we can connect to the server using p4 info
  local _, code, stderr = utils.job(utils.flatten({ p4_cmd, "info" }))
  if code ~= 0 then
      local err_msg = "Could not connect to Perforce server. Check P4PORT, P4USER, P4CLIENT settings."
      if stderr and #stderr > 0 then
          err_msg = err_msg .. "\nError: " .. table.concat(stderr, " ")
      end
      return err(err_msg)
  end

  -- Basic version check (optional, p4 versions are usually compatible)
  -- local out = utils.job(utils.flatten({ p4_cmd, "-V" }))
  -- bs.version_string = out[1] and out[1]:match("Rev%. P4/%S+/ (%S+)")

  bs.ok = true
end

---Perforce uses client root, not a specific .p4 dir like .git/.hg
---Paths need to be mapped relative to client root or use depot syntax.
function P4Adapter.get_repo_paths(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  -- Use `p4 info` to find the client root, which serves as the 'toplevel'
  local info_out, info_code = utils.job(utils.flatten({config.get_config().p4_cmd, "info"}))
  local client_root
  if info_code == 0 then
      for _, line in ipairs(info_out) do
          client_root = line:match("^Client root: (.*)")
          if client_root then client_root = vim.trim(client_root) break end
      end
  end

  if not client_root then
      logger:error("[P4Adapter] Could not determine Perforce client root via 'p4 info'.")
      -- Cannot reliably determine indicators without client root.
      -- Maybe fallback to cpath or cwd?
      table.insert(top_indicators, cpath or vim.loop.cwd())
      return path_args or {}, top_indicators -- Return original args and best guess
  end

  table.insert(top_indicators, client_root) -- The client root is the main indicator

  -- Try to resolve paths relative to client root if they aren't depot paths
  for _, path_arg in ipairs(path_args or {}) do
    local expanded_paths = pl:vim_expand(path_arg, false, true) or { path_arg } -- Expand wildcards etc.
    for _, path in ipairs(expanded_paths --[[@as string[] ]]) do
        if path:match("^//") then -- Already a depot path
            table.insert(paths, path)
        else
            local abs_path = pl:absolute(path, cpath)
            -- Check if the path is within the client root
            if abs_path:find(client_root, 1, true) == 1 then
                -- Attempt to map local path to depot path (might be complex due to view mapping)
                -- For simplicity, let's pass the local path relative to client root for now
                -- or maybe just the absolute path, and let p4 commands handle it.
                -- Using absolute local paths might be safer for commands like `p4 diff`.
                table.insert(paths, abs_path)
            else
                 -- Path is outside client root, pass it as is, p4 might handle it or error
                 table.insert(paths, path)
            end
        end
    end
  end

  return paths, top_indicators
end

function P4Adapter.find_toplevel(top_indicators)
    -- In Perforce, the "toplevel" is the client root.
    -- We try to get it from `p4 info` executed potentially within one of the indicator paths.
    local client_root

    for _, p in ipairs(top_indicators) do
        local target_dir = p
        if not pl:is_dir(p) then
            target_dir = pl:parent(p)
        end

        if target_dir and pl:readable(target_dir) then
            local info_out, info_code = utils.job(utils.flatten({config.get_config().p4_cmd, "info"}), target_dir)
            if info_code == 0 then
                 for _, line in ipairs(info_out) do
                    local root = line:match("^Client root: (.*)")
                    if root then
                       client_root = vim.trim(root)
                       -- Make sure it's a valid directory before returning
                       if pl:is_dir(client_root) then
                           return nil, client_root -- Found valid client root
                       else
                           client_root = nil -- Found path, but not a directory
                       end
                    end
                 end
            end
        end
        -- If we found a client root (even if not a dir yet), stop searching
        if client_root ~= nil then break end
    end

    if client_root then
        return nil, client_root -- Return whatever we found, validation happens later
    end

    return "Could not determine Perforce client root from provided paths.", ""
end

---@param toplevel string -- This will be the Client Root path
---@param path_args string[] -- Resolved paths (potentially absolute local or depot)
---@param cpath string?
---@return string? err
---@return P4Adapter
function P4Adapter.create(toplevel, path_args, cpath)
  local err
  local adapter = P4Adapter({
    toplevel = toplevel,
    path_args = path_args,
    cpath = cpath,
  })

  if not adapter.ctx.toplevel then
    err = "Could not find the Perforce client root!"
  elseif not pl:is_dir(adapter.ctx.toplevel) then
    err = "The Perforce client root is not a readable directory: " .. adapter.ctx.toplevel
  end

  -- No specific '.p4' directory like '.git' or '.hg'
  adapter.ctx.dir = adapter.ctx.toplevel -- Use client root as the conceptual 'dir'

  return err, adapter
end

---@param opt vcs.adapter.VCSAdapter.Opt
function P4Adapter:init(opt)
  opt = opt or {}
  self:super(opt) -- Calls base VCSAdapter init

  self.ctx = {
    toplevel = opt.toplevel, -- Client root
    dir = opt.toplevel,      -- Use client root as dir
    path_args = opt.path_args or {}, -- Use resolved paths
  }

  self:init_completion()
end

function P4Adapter:get_command()
  return config.get_config().p4_cmd -- Fetch from config
end

---Get arguments for `p4 print` to show file content at a revision.
---@param path string -- Can be local or depot path
---@param rev P4Rev?
function P4Adapter:get_show_args(path, rev)
  -- `p4 print -q` suppresses the header line
  local rev_spec = (rev and rev:object_name()) or "#head" -- Default to head if no rev specified
  -- If path is local, p4 print needs the depot path equivalent.
  -- This mapping can be complex. Let's assume for now the path is usable directly
  -- or the user provides depot paths. `p4 where` could map, but is slow.
  -- Let's try passing the path as is and add the revision.
  return utils.vec_join("print", "-q", path .. rev_spec)
end

---Get arguments for `p4 filelog` or `p4 changes`.
---@param args string[] -- This likely contains revision specs or paths
function P4Adapter:get_log_args(args)
  -- This function seems less used directly. History fetching uses specific commands.
  -- Maybe adapt for `p4 changes`?
  return utils.vec_join("changes", "-l", args) -- Example: get long description for changes
end

---Perforce doesn't have a distinct VCS dir like .git/.hg
function P4Adapter:get_dir(path)
  return self.ctx.toplevel -- Client root serves this purpose
end

---Verify a revision specifier.
---@param rev_arg string
---@return boolean ok, string[] output
function P4Adapter:verify_rev_arg(rev_arg)
  -- Use `p4 changes -m1` to check if a revision specifier resolves to at least one CL.
  -- Handle special cases like #head, #none, @
  if rev_arg == "#head" or rev_arg == "#none" or rev_arg == "@" then
      return true, { rev_arg } -- Assume these are valid
  end

  local out, code = self:exec_sync({ "changes", "-m1", rev_arg }, {
    log_opt = { label = "P4Adapter:verify_rev_arg()" },
    cwd = self.ctx.toplevel,
  })
  return code == 0 and #out > 0, out
end

---Get context for merges (Perforce resolve state). This is complex.
---`p4 resolve -n` might show files needing resolve. Getting specific base/ours/theirs
---revisions per file might require parsing `p4 diff -Od //file...` etc.
---Let's return nil for now, as merge tool support requires significant work.
---@return vcs.MergeContext?
function P4Adapter:get_merge_context()
    -- Basic check if resolves are pending
    local out, code = self:exec_sync({"resolve", "-n", "//..."}, self.ctx.toplevel)
    if code == 0 and #out > 0 then
        -- Files need resolving, but getting base/theirs/ours info reliably is hard.
        logger:warn("[P4Adapter] Merge/resolve context detection is limited. Files may require resolve.")
        -- Return a placeholder structure or nil? Returning nil disables merge features.
        return nil
    end
    return nil
end

-- File History Implementation

---@class P4Adapter.PreparedLogOpts
---@field rev_range string? -- e.g., @CL1,@CL2
---@field path_args string[]
---@field flags string[] -- Additional flags like -l, -t for filelog

---@param log_options HgLogOptions -- Re-using HgLogOptions structure for now
---@param single_file boolean
---@return P4Adapter.PreparedLogOpts
function P4Adapter:prepare_fh_options(log_options, single_file)
  local o = log_options
  local rev_range

  -- Perforce range syntax is typically path@rev1,rev2 or just path for all history
  if o.rev then
      rev_range = o.rev -- Assuming o.rev contains the P4 range spec like @CL1,@CL2
  end

  -- Note: Perforce flags differ significantly from Git/Hg. Adapt as needed.
  -- `-l` for long output (includes description) in `p4 changes`
  -- `-t` for timestamps in `p4 filelog`
  local flags = {}
  if o.limit then table.insert(flags, "-m" .. o.limit) end
  -- Add other relevant flags based on HgLogOptions mapping if desired
  -- if o.user then table.insert(flags, "-u" .. o.user) end -- `p4 changes -u user`

  return {
    rev_range = rev_range,
    path_args = log_options.path_args, -- Should contain file/dir paths
    flags = flags,
  }
end

---Dry run for file history command.
---@param log_opt table -- P4 specific options based on HgLogOptions mapping
---@return boolean ok, string description
function P4Adapter:file_history_dry_run(log_opt)
  local single_file = #log_opt.path_args == 1 -- Basic check, doesn't verify if path is file/dir
  local log_options = config.get_log_options(single_file, log_opt, self.config_key)
  local prepared_opts = self:prepare_fh_options(log_options, single_file)

  local description_parts = {
    fmt("Client Root: '%s'", pl:vim_fnamemodify(self.ctx.toplevel, ":~")),
  }
  if prepared_opts.rev_range then
      table.insert(description_parts, fmt("Revision Range: '%s'", prepared_opts.rev_range))
  end
  if #prepared_opts.flags > 0 then
      table.insert(description_parts, fmt("Flags: %s", table.concat(prepared_opts.flags, " ")))
  end
  local description = table.concat(description_parts, ", ")

  -- Command to check: Use 'p4 changes' or 'p4 filelog' with -m1 limit
  local cmd
  if single_file then
      cmd = utils.vec_join("filelog", "-m1", prepared_opts.flags, prepared_opts.path_args[1] .. (prepared_opts.rev_range or ""))
  else
      cmd = utils.vec_join("changes", "-m1", prepared_opts.flags, (prepared_opts.path_args[1] or "//...") .. (prepared_opts.rev_range or ""))
  end

  local out, code = self:exec_sync(cmd, {
    cwd = self.ctx.toplevel,
    log_opt = { label = "P4Adapter:file_history_dry_run()" },
  })

  local ok = code == 0 and #out > 0
  if not ok then
      logger:fmt_debug("[P4Adapter] Dry run failed for file history.")
  end
  return ok, description
end

---Parse options for :DiffviewFileHistory for Perforce.
---@param range? { [1]: integer, [2]: integer } -- Ignored for P4
---@param paths string[] -- Raw paths from command line
---@param argo ArgObject
function P4Adapter:file_history_options(range, paths, argo)
  if range then
    utils.warn("Line ranges are not supported for Perforce history.")
  end

  -- Use mapped options similar to Hg, adjust keys/flags as needed
  local log_flag_names = {
    { "rev" },         -- Map to P4 revision range/specifier
    { "limit", "m" },  -- Map to -m max
    { "user", "u" },   -- Map to -u user
    -- Add more mappings if needed (e.g., -l for long desc in changes)
    -- { "long", "l" },
  }

  local log_options = {} --[[@as table ]]
  for _, names in ipairs(log_flag_names) do
    local key = names[1]
    local v = argo:get_flag(names, {
        expect_string = key ~= 'long', -- Adjust based on flag type
    })
    -- Use the Perforce flag name as the key if different (e.g., limit vs m)
    log_options[key] = v
  end

  log_options.path_args = paths -- Store the raw paths provided

  -- Validate options and paths using a dry run
  local ok, opt_description = self:file_history_dry_run(log_options)
  if not ok then
    local target_desc = #paths > 0 and table.concat(paths, ", ") or "client view"
    utils.info(fmt(
        "No Perforce history found for target(s) with current options.\nTargets: %s\nOptions: [ %s ]",
        target_desc, opt_description
    ))
    return nil -- Indicate failure
  end

  return log_options -- Return the parsed options
end


---@class P4Adapter.FHState
---@field path_args string[]
---@field log_options table -- P4 specific options
---@field prepared_log_opts P4Adapter.PreparedLogOpts
---@field layout_opt vcs.adapter.LayoutOpt
---@field single_file boolean

--- Worker to fetch and process file history. Uses `p4 changes` and `p4 describe`.
---@param self P4Adapter
---@param out_stream AsyncListStream
---@param opt vcs.adapter.FileHistoryWorkerSpec -- Contains log_opt etc.
P4Adapter.file_history_worker = async.void(function(self, out_stream, opt)
    local single_file_opt = opt.log_opt and opt.log_opt.single_file
    local single_file = single_file_opt and #single_file_opt.path_args == 1 or false

    ---@type table
    local log_options = config.get_log_options(
        single_file,
        single_file and single_file_opt or opt.log_opt.multi_file,
        "p4"
    )

    ---@type P4Adapter.FHState
    local state = {
        path_args = log_options.path_args or {}, -- Ensure path_args exists
        log_options = log_options,
        prepared_log_opts = self:prepare_fh_options(log_options, single_file),
        layout_opt = opt.layout_opt,
        single_file = single_file,
    }

    logger:info("[P4 FileHistory] Updating with options:", vim.inspect(state.prepared_log_opts))

    local path_spec = #state.path_args > 0 and state.path_args[1] or "//..." -- Default to full depot if no path
    local rev_spec = state.prepared_log_opts.rev_range or "" -- e.g., @CL1,@CL2

    -- Command to get relevant changelists
    local changes_cmd = utils.vec_join(
        "changes", "-l", -- Use -l for description
        state.prepared_log_opts.flags, -- Contains -m limit, -u user etc.
        path_spec .. rev_spec
    )

    local changes_job = Job({
        command = self:bin(),
        args = changes_cmd,
        cwd = self.ctx.toplevel,
        log_opt = { label = "P4Adapter:file_history_worker(changes)" },
    })

    local ok, err = await(changes_job)
    if not ok or changes_job.code ~= 0 then
        local err_msg = "Failed to fetch Perforce changes."
        if err then table.insert(err, err_msg) end
        out_stream:push({ JobStatus.ERROR, nil, table.concat(utils.vec_join(err, changes_job.stderr), "\n") })
        out_stream:close()
        return
    end

    -- Process changes output line by line or parse structured output if available
    local changelists = {}
    for _, line in ipairs(changes_job.stdout) do
        local cl = line:match("^Change (%d+)")
        if cl then table.insert(changelists, cl) end
    end

    if #changelists == 0 then
        out_stream:push({ JobStatus.SUCCESS }) -- No history found
        out_stream:close()
        return
    end

    -- Fetch details for each changelist using p4 describe
    local interval = (1000 / 10) * 1E6 -- Limit rate slightly
    local last_wait = uv.hrtime()

    for _, cl in ipairs(changelists) do
         -- Yield periodically
        local now = uv.hrtime()
        if (now - last_wait > interval) then
            last_wait = now
            await(async.schedule_now())
        end

        if out_stream:is_closed() then return end -- Check if consumer closed

        local describe_job = Job({
            command = self:bin(),
            args = { "describe", cl },
            cwd = self.ctx.toplevel,
            log_opt = { label = fmt("P4Adapter:file_history_worker(describe %s)", cl) },
        })

        ok, err = await(describe_job)
        if not ok or describe_job.code ~= 0 then
             logger:fmt_error("Failed to describe changelist %s: %s", cl, table.concat(utils.vec_join(err, describe_job.stderr), "\n"))
             -- Decide whether to error out or just skip this CL
             goto continue -- Skip this problematic CL
        end

        -- Parse describe output to create Commit and FileEntry objects
        local commit_data = Commit.from_rev_arg("@"..cl, self) -- Use commit class parser
        if not commit_data then
             logger:fmt_warn("Could not parse commit data for CL %s", cl)
             goto continue -- Skip if parsing failed
        end

        local parsed_describe = parse_describe_output(describe_job.stdout) -- Re-use helper if needed
        local files_in_cl = parsed_describe.files or {}

        local file_entries = {}
        for _, file_info in ipairs(files_in_cl) do
            -- Check if this file matches the requested path_args if any
            local path_matches = true
            if #state.path_args > 0 then
                 -- Basic check: does the file path start with one of the arg paths?
                 -- Needs improvement for complex view mappings / wildcards.
                 path_matches = false
                 for _, arg_path in ipairs(state.path_args) do
                     -- Strip the Perforce recursive wildcard ("...") so we can
                     -- do a plain prefix match against the depot path.  E.g.
                     -- "//depot/main/..." becomes "//depot/main/" and will
                     -- match "//depot/main/foo.c".  This is intentionally
                     -- simplistic and won't handle all view-mapping edge cases.
                     if file_info.path:find(arg_path:gsub("%.%.%.", ""), 1, true) then
                         path_matches = true
                         break
                     end
                 end
            end

            if path_matches then
                -- Determine previous revision for diffing (usually CL-1, but complex for integrations)
                -- `p4 filelog -m1 file@CL` gives previous action.
                -- For simplicity, let's assume diff against CL-1.
                local prev_cl_num = tonumber(cl) - 1
                local prev_rev_spec = "@" .. tostring(prev_cl_num)

                -- Convert P4 action to Git status symbol (approximate mapping)
                local status_map = { add = "A", edit = "M", delete = "D", branch = "A", integrate = "M" }
                local status = status_map[file_info.action] or "M"

                table.insert(file_entries, FileEntry.with_layout(
                    state.layout_opt.default_layout or Diff2Hor,
                    {
                        adapter = self,
                        path = file_info.path, -- Use depot path
                        status = status,
                        stats = nil, -- `p4 describe` doesn't give diff stats easily
                        kind = "working", -- Treat as 'working' kind for simplicity
                        commit = commit_data,
                        revs = {
                            a = P4Rev(RevType.COMMIT, prev_rev_spec), -- Previous revision
                            b = P4Rev(RevType.COMMIT, "@"..cl),      -- This revision
                        },
                    }
                ))
            end
        end

        if #file_entries > 0 then
             local entry = LogEntry({
                path_args = state.path_args,
                commit = commit_data,
                files = file_entries,
                single_file = state.single_file,
            })
            out_stream:push({ JobStatus.PROGRESS, entry })
        else
            -- Log entry might be empty if the CL didn't affect the filtered path
            -- logger:fmt_debug("Changelist %s did not affect requested paths.", cl)
        end

        ::continue::
    end

    out_stream:push({ JobStatus.SUCCESS })
    out_stream:close()
end)

-- Diff View Implementation

--- Parse revision arguments for :DiffviewOpen
---@param argo ArgObject
function P4Adapter:diffview_options(argo)
  local rev_arg = argo.args[1] -- e.g., @CL, CL1..CL2, #head
  local left, right

  if not rev_arg then
    -- Default: workspace vs head
    left = P4Rev(RevType.COMMIT, "#head")
    right = P4Rev(RevType.LOCAL) -- Represents workspace
  elseif rev_arg:match("^(@?%d+)%.%.(@?%d+)$") or rev_arg:match("^(@?%d+),(@?%d+)$") then
      -- Range specified CL1..CL2 or @CL1,@CL2
      local r1, r2 = rev_arg:match("^(@?%d+)[%.%.,](@?%d+)$")
      local ok1, _ = self:verify_rev_arg(r1)
      local ok2, _ = self:verify_rev_arg(r2)
      if ok1 and ok2 then
          left = P4Rev(RevType.COMMIT, r1)
          right = P4Rev(RevType.COMMIT, r2)
      else
          utils.err("Invalid revision range specified: " .. rev_arg)
          return nil
      end
  else
    -- Single revision specified, e.g., @CL, CL, #head
    -- Compare this revision against the workspace? Or show diff *within* the CL?
    -- Let's default to showing the diff *within* the CL (like `git show`)
    -- This requires comparing CL vs CL-1.
    local ok, resolved = self:verify_rev_arg(rev_arg)
    if not ok then
        utils.err("Invalid revision specified: " .. rev_arg)
        return nil
    end
    local current_rev_spec = resolved[1] -- Use resolved spec if possible
    local cl_num = current_rev_spec:match("@(%d+)")
    if cl_num then
        local prev_cl_num = tonumber(cl_num) - 1
        left = P4Rev(RevType.COMMIT, "@" .. prev_cl_num) -- CL-1
        right = P4Rev(RevType.COMMIT, current_rev_spec) -- CL
    else
        -- Cannot easily determine previous rev for non-CL specs like #head or labels
        -- Fallback to comparing spec against workspace?
        -- Or maybe error out? Let's compare against workspace for now.
        left = P4Rev(RevType.COMMIT, current_rev_spec)
        right = P4Rev(RevType.LOCAL)
        -- utils.warn("Comparing single non-CL revision against workspace. To see diff *within* a CL, specify the changelist number.")
    end
  end

  ---@type DiffViewOptions
  local options = {
    show_untracked = false, -- Untracked files less relevant in P4 workflows usually
    selected_file = argo:get_flag("selected-file", { no_empty = true, expand = true })
      or (vim.bo.buftype == "" and pl:vim_expand("%:p"))
      or nil,
  }

  return { left = left, right = right, options = options }
end

---Convert Diffview Revs to p4 command arguments for diffing.
---@param left Rev
---@param right Rev
---@return string[] Arguments for `p4 diff` or `p4 diff2`
function P4Adapter:rev_to_args(left, right)
  local left_spec = left:object_name()
  local right_spec = right:object_name()

  if right.type == RevType.LOCAL then
    -- Diffing against workspace: `p4 diff //path/...#rev` or just `p4 diff //path/...`
    if left_spec == "#head" then
        return {} -- `p4 diff` defaults to workspace vs head
    else
        -- Need to specify the revision for the depot side. Path args are added later.
        -- Returning just the rev spec might work if paths are appended correctly.
        -- `p4 diff` doesn't take two revisions like diff2.
        -- This case might need handling in the calling function (`tracked_files`).
        -- Let's return an empty array and handle it there.
        return {}
    end
  elseif left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    -- Diffing between two depot revisions: `p4 diff2 //path/...@rev1 //path/...@rev2`
    -- We return the specs; the calling function needs to apply them to paths.
    return { left_spec, right_spec }
  end

  -- Other combinations might not be directly supported or require different commands.
  logger:fmt_warn("Unsupported revision combination for diffing: %s vs %s", left_spec, right_spec)
  return {}
end

---Get tracked files (opened or diff between revs).
---@param self P4Adapter
---@param left Rev
---@param right Rev
---@param args string[] -- Usually empty, paths are handled separately?
---@param kind vcs.FileKind -- "working", "staged" (not applicable), "conflicting"
---@param opt vcs.adapter.LayoutOpt
---@param callback fun(err?:any, files?:FileEntry[], conflicts?:FileEntry[])
P4Adapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
    local files = {}
    local conflicts = {} -- Perforce conflicts detected via 'p4 resolve -n'
    local log_opt = { label = "P4Adapter:tracked_files()" }
    local path_args = self.ctx.path_args -- Use paths stored in adapter context

    -- Default pathspec if none provided in context
    local path_spec = #path_args > 0 and path_args or { "//..." }

    if right.type == RevType.LOCAL then
        -- Compare workspace (local) against a depot revision (left)
        local depot_rev = left:object_name()

        -- Use `p4 diff -f -sl //...@depot_rev` to list files differing from depot rev
        -- Use `p4 opened //...` to list files opened for edit/add/delete etc.
        -- Combine results for a complete view.

        local diff_job = Job({
            command = self:bin(),
            -- -sl lists files differing, -f forces diff even if identical (for adds/deletes)
            args = utils.vec_join("diff", "-sl", vim.tbl_map(function(p) return p .. depot_rev end, path_spec)),
            cwd = self.ctx.toplevel,
            log_opt = { label = log_opt.label .. "(diff)" },
        })
        local opened_job = Job({
            command = self:bin(),
            args = utils.vec_join("opened", path_spec),
            cwd = self.ctx.toplevel,
            log_opt = { label = log_opt.label .. "(opened)" },
        })

        local ok, err = await(Job.join({ diff_job, opened_job }))
        if not ok then
            callback(utils.vec_join(err, diff_job.stderr, opened_job.stderr), nil)
            return
        end

        local file_status = {} -- path -> { status, path, oldpath, stats }

        -- Process opened files first to get status (add, edit, delete).
        -- p4 opened output format: //depot/path#rev - action change (type)
        -- Strip the #rev suffix to get just the depot path.
        for _, line in ipairs(opened_job.stdout) do
            local depot_path, change_type, cl_info = line:match("^(.-)#%d+%s*-%s*([^%s]+)%s+(.*)")
            if depot_path then
                local status_map = { add = "A", edit = "M", delete = "D", branch = "A", integrate = "M" }
                local status = status_map[change_type] or "M" -- Default to modified
                file_status[depot_path] = { status = status, path = depot_path }
            end
        end

        -- Process diff output, update status if needed, add files not in 'opened'.
        -- p4 diff -sl output format: "diff /local/path" or "same /local/path".
        -- We only care about files that differ ("diff" status).  The paths are
        -- local workspace paths, so we need to map them back to depot paths via
        -- `p4 where` or by matching against already-known opened files.  For
        -- now, record the local path directly when the file is not already in
        -- the opened set.
        for _, line in ipairs(diff_job.stdout) do
             local diff_status, local_path = line:match("^(%S+) (.+)$")
             if diff_status == "diff" and local_path then
                 -- Check if this local path corresponds to an already-opened depot path.
                 -- If not, record it as a modified file that may need reconciling.
                 local found = false
                 for _, data in pairs(file_status) do
                     if data.path == local_path then
                         found = true
                         break
                     end
                 end
                 if not found then
                     file_status[local_path] = { status = "M", path = local_path }
                 end
             end
        end

        -- Convert file_status map to FileEntry array
        for _, data in pairs(file_status) do
            table.insert(files, FileEntry.with_layout(opt.default_layout, {
                adapter = self,
                path = data.path,
                status = data.status,
                stats = data.stats, -- nil for now
                kind = "working",
                revs = { a = left, b = right },
            }))
        end

    elseif left.type == RevType.COMMIT and right.type == RevType.COMMIT then
        -- Compare two depot revisions
        local left_spec = left:object_name()
        local right_spec = right:object_name()

        -- Use `p4 diff2 -q //path/...@rev1 //path/...@rev2` to get diff summary
        -- Or `p4 files //path/...@rev1,@rev2` then `p4 diff2`?
        -- Or `p4 describe -du CL` if it represents a single CL change.
        -- Let's use diff2 -ds for summary between two arbitrary revisions.
        local diff_cmd = utils.vec_join(
            "diff2", "-ds", -- -ds provides summary status line per file
            vim.tbl_map(function(p) return p .. left_spec end, path_spec),
            vim.tbl_map(function(p) return p .. right_spec end, path_spec)
        )

        local diff_job = Job({
            command = self:bin(),
            args = diff_cmd,
            cwd = self.ctx.toplevel,
            log_opt = { label = log_opt.label .. "(diff2)" },
        })

        local ok, err = await(diff_job)
        if not ok then
            callback(utils.vec_join(err, diff_job.stderr), nil)
            return
        end

        -- Parse `diff2 -ds` output.  The format varies:
        --   ==== //path#rev (type) - //path#rev (type) ==== content
        --   ==== //path#rev (type) - //path#rev (type) ==== identical
        --   ==== <none> - //path#rev ====               (added file)
        --   ==== //path#rev - <none> ===                (deleted file, note 3 '=')
        -- Stats lines like "add 0 chunks 0 lines" follow and are ignored.
        for _, line in ipairs(diff_job.stdout) do
          if line:match("^====") then
            local left_file, right_file, diff_type =
              line:match("^==== (%S+).-%-(.-)===+%s*(%S*)")

            if left_file then
              right_file = right_file:match("(%S+)") or right_file

              local status
              if diff_type == "content" then status = "M"
              elseif diff_type == "types" then status = "T"
              elseif diff_type == "branch" then status = "A"
              elseif left_file == "<none>" then status = "A"
              elseif right_file == "<none>" then status = "D"
              elseif diff_type == "identical" then status = nil
              else status = "M"
              end

              if status then
                -- Strip #rev suffix from depot paths.
                local path = left_file ~= "<none>" and left_file or right_file
                path = path:match("^(.-)#%d+") or path

                table.insert(files, FileEntry.with_layout(opt.default_layout, {
                    adapter = self,
                    path = path,
                    status = status,
                    stats = nil,
                    kind = "working",
                    revs = { a = left, b = right },
                }))
              end
            end
          end
        end
    else
        logger:fmt_warn("Unsupported revision combination for tracked_files: %s vs %s", left, right)
    end

    -- Check for conflicts separately if needed (complex)
    -- local conflict_check_job = ... `p4 resolve -n` ...
    -- if conflicts_found then populate `conflicts` array

    -- Sort files alphabetically by path
    table.sort(files, function(a, b) return a.path < b.path end)

    callback(nil, files, conflicts)
end)

---Get untracked files (files in workspace not known to Perforce).
---Uses `p4 status` (reconcile).
---@param self P4Adapter
---@param left Rev
---@param right Rev
---@param opt vcs.adapter.LayoutOpt
---@param callback fun(err?:any, files?:FileEntry[])
P4Adapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
    -- Only show untracked if comparing against workspace AND configured to do so
    if right.type ~= RevType.LOCAL or not self:show_untracked({ revs = { left=left, right=right }}) then
        callback(nil, {})
        return
    end

    local path_args = self.ctx.path_args
    local path_spec = #path_args > 0 and path_args or { "//..." }

    -- `p4 status` or `p4 reconcile -nlad` lists local files not in depot or opened.
    local status_job = Job({
        command = self:bin(),
        args = utils.vec_join("reconcile", "-nl", path_spec), -- -n: preview, -l: local files not in depot
        cwd = self.ctx.toplevel,
        log_opt = { label = "P4Adapter:untracked_files()" },
    })

    local ok, err = await(status_job)
    if not ok then
        callback(utils.vec_join(err, status_job.stderr), nil)
        return
    end

    local files = {}
    for _, line in ipairs(status_job.stdout) do
        -- Output format: //depot/path#none - add default changelist (local) /path/on/disk
        local local_path = line:match("%(local%)%s*(.*)")
        if local_path then
             local_path = vim.trim(local_path)
            -- We need the path relative to client root or the depot path if possible
            -- Sticking with the local path for now.
            table.insert(files, FileEntry.with_layout(opt.default_layout, {
                adapter = self,
                path = local_path, -- Use local path for untracked
                status = "?",
                stats = nil,
                kind = "working",
                revs = { a = P4Rev.new_null_tree(), b = right }, -- Diff from nothing to local
            }))
        end
    end

    callback(nil, files)
end)

---Check configuration/defaults if untracked files should be shown.
---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function P4Adapter:show_untracked(opt)
  opt = opt or {}
  -- Only potentially show untracked when comparing against workspace
  if opt.revs and opt.revs.right.type ~= RevType.LOCAL then
    return false
  end
  -- Check user config if explicitly disabled (add a p4 specific config option?)
  -- local conf = config.get_config()
  -- if conf.p4 and conf.p4.show_untracked == false then return false end

  -- Default to false for Perforce as untracked files are less common in typical workflows
  return false
end

---Restore file using `p4 revert`.
---@param self P4Adapter
---@param path string -- Can be local or depot path
---@param kind vcs.FileKind -- "working", "conflicting" etc.
---@param commit string? -- Ignored for p4 revert (reverts to depot head or unopened state)
---@param callback fun(ok: boolean, undo?: string)
P4Adapter.file_restore = async.wrap(function(self, path, kind, commit, callback)
    -- `p4 revert` reverts opened files to their state before being opened,
    -- or removes added files. It doesn't restore to a specific historical commit.
    -- If the goal is to revert changes made in the workspace:
    local revert_job = Job({
        command = self:bin(),
        args = { "revert", path },
        cwd = self.ctx.toplevel,
        log_opt = { label = "P4Adapter:file_restore(revert)" },
    })

    local ok, err = await(revert_job)
    if not ok then
        callback(false, nil) -- Revert failed
        return
    end

    -- Check if the file still exists after revert (it might if it was edited, not if added)
    local exists_local = pl:readable(path) -- Assumes path is local absolute

    -- Constructing an "undo" command for p4 revert is difficult.
    -- Maybe sync to the previous revision?
    local undo_cmd -- = nil (Hard to provide a reliable undo for p4 revert)

    callback(true, undo_cmd)
end)

--- Staging is implicit via `p4 add/edit/delete`. This doesn't map well.
---@param file vcs.File
function P4Adapter:stage_index_file(file)
  logger:warn("[P4Adapter] Staging via index buffer not supported for Perforce.")
  return false -- Indicate not supported/failed
end

--- Add files using `p4 add`.
function P4Adapter:add_files(paths)
  local _, code = self:exec_sync(utils.vec_join("add", paths), self.ctx.toplevel)
  return code == 0
end

--- Reset/Revert files using `p4 revert`.
function P4Adapter:reset_files(paths)
  local _, code = self:exec_sync(utils.vec_join("revert", paths), self.ctx.toplevel)
  return code == 0
end

--- Check if a file is binary using `p4 fstat`.
---@param path string -- Depot or local path
---@param rev P4Rev -- Revision to check
---@return boolean -- True if binary or non-existent
function P4Adapter:is_binary(path, rev)
    -- File type check works best on depot paths and revisions.
    local path_spec = path
    if rev and rev.type == RevType.COMMIT then
        path_spec = path .. rev:object_name()
    elseif rev and rev.type == RevType.LOCAL then
        path_spec = path
    else
        path_spec = path .. "#head"
    end

    local out, code = self:exec_sync(
      { "fstat", "-T", "headType", path_spec },
      self.ctx.toplevel
    )

    if code ~= 0 then
        return true -- Assume binary or non-existent on error
    end

    for _, line in ipairs(out) do
        local file_type = line:match("headType (%S+)")
        if file_type then
            if file_type:find("binary")
              or file_type:find("apple")
              or file_type:find("resource")
              or file_type:find("unicode")
              or file_type:find("utf16")
            then
                return true
            else
                return false
            end
        end
    end

    return true -- Not found or no type info, assume binary/non-existent
end

---Convert revs to pretty string for display.
---@param left Rev
---@param right Rev
---@return string|nil
function P4Adapter:rev_to_pretty_string(left, right)
  local l_str = left:object_name()
  local r_str = right:object_name()

  if right.type == RevType.LOCAL then
      return l_str -- Show only the depot revision being compared to workspace
  else
      if l_str ~= P4Rev.NULL_TREE_SHA and r_str ~= P4Rev.NULL_TREE_SHA and l_str ~= r_str then
          return l_str .. ".." .. r_str
      else
           return r_str -- Show single revision if left is null or same
      end
  end
end

-- Completion Setup

--- Placeholder for Perforce completion logic.
function P4Adapter:init_completion()
    -- Completion for :DiffviewOpen [rev]
    self.comp.open:put({}, function(_, arg_lead) -- No specific flags yet
        -- Provide CLs, #head, @, labels?
        return self:rev_candidates(arg_lead, { accept_range = true })
    end)

    -- Completion for :DiffviewFileHistory flags
    self.comp.file_history:put({ "--rev", "-r" }, function(_, arg_lead)
        -- Provide CLs, #head, @rev1,@rev2 ranges, labels
        return self:rev_candidates(arg_lead, { accept_range = true })
    end)
    self.comp.file_history:put({ "--limit", "-m" }, {}) -- Expects number
    self.comp.file_history:put({ "--user", "-u" }, function(_, arg_lead)
        -- Provide list of users? `p4 users`
        -- local users_out, _ = self:exec_sync({"users", "-a"}, self.ctx.toplevel)
        -- return vim.tbl_map(function(l) return l:match("^(%S+)") end, users_out or {})
        return {} -- Placeholder
    end)
     self.comp.file_history:put({ "--" }, function(_, arg_lead) -- Path completion
        return self:path_candidates(arg_lead)
    end)

    -- Add other completions as needed
end

--- Provide revision candidates for completion.
---@param arg_lead string
---@param opt? RevCompletionSpec
function P4Adapter:rev_candidates(arg_lead, opt)
    opt = vim.tbl_extend("keep", opt or {}, { accept_range = false }) --[[@as RevCompletionSpec ]]
    local candidates = { "#head", "#none", "@" } -- Basic specs

    -- Fetch recent changes
    local changes_out, _ = self:exec_sync({"changes", "-m", "20", "-s", "submitted", "//..."}, self.ctx.toplevel)
    for _, line in ipairs(changes_out or {}) do
        local cl = line:match("^Change (%d+)")
        if cl then table.insert(candidates, "@" .. cl) end
    end

    -- Fetch labels (can be slow)
    -- local labels_out, _ = self:exec_sync({"labels"}, self.ctx.toplevel)
    -- for _, line in ipairs(labels_out or {}) do
    --    local label = line:match("^Label (%S+)")
    --    if label then table.insert(candidates, "@" .. label) end
    -- end

    -- Handle range completion if needed
    if opt.accept_range then
       -- Logic similar to Git/Hg to prepend range prefix to candidates
       local range_prefix = arg_lead:match("^(.-[,%.%.])")
       if range_prefix then
           local remaining_lead = arg_lead:sub(#range_prefix + 1)
           local filtered_candidates = vim.tbl_filter(function(c) return c:find(remaining_lead, 1, true) == 1 end, candidates)
           return vim.tbl_map(function(c) return range_prefix .. c end, filtered_candidates)
       end
    end

    -- Filter candidates based on arg_lead
    return vim.tbl_filter(function(c) return c:find(arg_lead, 1, true) == 1 end, candidates)
end

--- Provide path candidates for completion (depot paths).
---@param arg_lead string
function P4Adapter:path_candidates(arg_lead)
    -- Use `p4 files` or `p4 dirs` for completion.
    -- Needs careful handling of depot vs local paths and view mapping.
    local cmd
    local pattern = arg_lead
    if not pattern:match("^//") then
       -- Assume it's a local path relative to CWD or client root? Map it?
       -- For simplicity, default to completing from depot root if not a depot path.
       pattern = "//..."
       if arg_lead ~= "" then pattern = arg_lead .. "*" end -- Basic wildcard
    else
       pattern = arg_lead .. "*" -- Add wildcard for directory listing effect
    end

    -- Use 'p4 dirs' for directory completion
    cmd = { "dirs", pattern }
    local dirs_out, _ = self:exec_sync(cmd, self.ctx.toplevel)

    -- Use 'p4 files' for file completion (limit results?)
    cmd = { "files", "-m", "20", pattern:gsub("%*$", "") .. "..." } -- Limit files shown
    local files_out, _ = self:exec_sync(cmd, self.ctx.toplevel)

    local candidates = {}
    for _, line in ipairs(dirs_out or {}) do table.insert(candidates, line) end
    for _, line in ipairs(files_out or {}) do
        local file_path = line:match("^(%S+)#")
        if file_path then table.insert(candidates, file_path) end
    end

    return candidates
end


M.P4Adapter = P4Adapter
return M
