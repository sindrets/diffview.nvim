local lazy = require("diffview.lazy")
local oop = require('diffview.oop')
local Commit = require('diffview.vcs.commit').Commit
local RevType = require('diffview.vcs.rev').RevType
local utils = require('diffview.utils')

local M = {}

---@class P4Commit : Commit
local P4Commit = oop.create_class('P4Commit', Commit)

---P4Commit constructor
---@param opt table
function P4Commit:init(opt)
  self:super(opt) -- Calls base Commit init

  -- Perforce describe output gives Unix timestamp directly.
  -- Timezone handling might require parsing the date string or relying on system locale.
  -- Let's use the raw timestamp and format it simply for now.
  if self.time then
      self.iso_date = os.date("%Y-%m-%d %H:%M:%S", self.time) -- Simple local time formatting
      self.rel_date = utils.relative_time(self.time) -- Use existing utility if possible
  end
  self.hash = opt.changelist -- Store CL number as 'hash' for consistency
end

-- Helper to parse p4 describe output
local function parse_describe_output(output_lines)
    local data = { files = {} }
    local reading_files = false
    local reading_diff = false
    local current_file_diff = {}

    for i, line in ipairs(output_lines) do
        if not reading_files and not reading_diff then
            local cl, date_str, user_at_client, desc_start = line:match("^Change (%d+) on ([^%s]+) by ([^@]+@[^%s]+) (.*)")
            if cl then
                data.changelist = cl
                -- Attempt to parse date - p4 dates can be yyyy/mm/dd:hh:mm:ss
                -- Let's stick to the Unix timestamp provided later for accuracy
                data.user = user_at_client:match("^(.*)@")
                data.client = user_at_client:match("@(.*)$")
                data.description = desc_start .. "\n"
            elseif line:match("^Description:") then
                 -- Ignore, handled above or description continues
            elseif line:match("^Affected files ...") or line:match("^Differences ...") then
                reading_files = true
            else -- Continue capturing multi-line description
                if data.description and line:match("^ ") then -- Indented lines are part of desc
                   data.description = data.description .. line:sub(2) .. "\n"
                end
            end
        elseif reading_files then
            local path, rev, action = line:match("^... (%S+)#(%d+) (%S+)")
            if path then
                table.insert(data.files, { path = path, rev = rev, action = action })
            elseif line:match("^Differences ...$") then
                reading_files = false
                reading_diff = true
            elseif line ~= "" then
                -- A non-empty, non-matching line ends the file section.
                reading_files = false
            end
            -- Blank lines inside the file section are expected (p4 describe
            -- inserts one between "Affected files ..." and the first entry)
            -- and should be skipped rather than ending the section.
        -- elseif reading_diff then
            -- Diff parsing is handled separately if needed, `p4 describe -du` gives unified diff
        end
        -- Look for the timestamp which is usually near the end
        local time_unix = line:match("^%*edit @ (%d+)") or line:match("^%*add @ (%d+)") or line:match("^%*delete @ (%d+)") or line:match("^%*branch @ (%d+)") or line:match("^%*integrate @ (%d+)")
         if time_unix then
            data.time = tonumber(time_unix)
         end
    end
    -- Clean up description whitespace
    if data.description then
        data.description = vim.trim(data.description)
    end

    -- Simple relative date calculation based on timestamp
    if data.time then
       data.rel_date = utils.relative_time(data.time)
    else
       -- Fallback if timestamp wasn't found (unlikely for submitted CLs)
       data.rel_date = "unknown"
    end

    return data
end


---@param rev_arg string # Changelist number or specifier like @CL
---@param adapter P4Adapter
---@return P4Commit?
function P4Commit.from_rev_arg(rev_arg, adapter)
  local cl_num = rev_arg:match("^@(%d+)$") or rev_arg:match("^(%d+)$")
  if not cl_num then
    -- Handle other revspecs? For now, only support CL numbers for commit details.
    -- Could potentially support labels or #head, but describe works best with CLs.
    -- Maybe run 'p4 changes -m1 rev_arg' first to resolve to a CL number.
    local resolve_out, resolve_code = adapter:exec_sync({ "changes", "-m1", rev_arg }, adapter.ctx.toplevel)
    if resolve_code ~= 0 or #resolve_out == 0 then return nil end
    cl_num = resolve_out[1]:match("^Change (%d+)")
    if not cl_num then return nil end
  end

  -- Fetch changelist details using p4 describe
  local out, code = adapter:exec_sync({ "describe", cl_num }, adapter.ctx.toplevel)

  if code ~= 0 or #out == 0 then
    return nil
  end

  local data = parse_describe_output(out)
  if not data.changelist then return nil end

  return P4Commit({
    changelist = data.changelist, -- Store the actual CL number
    hash = data.changelist,       -- Use CL number as 'hash' for internal consistency
    author = data.user,
    time = data.time,             -- Unix timestamp
    subject = data.description:match("^[^\n]*") or ("Changelist " .. data.changelist), -- First line of description
    body = data.description,
    rel_date = data.rel_date,     -- Calculated relative date
    -- Perforce doesn't have direct ref names like git branches/tags in describe output
  })
end

M.P4Commit = P4Commit
M.parse_describe_output = parse_describe_output
return M
