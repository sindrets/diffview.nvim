local helpers = require("diffview.tests.helpers")
local config = require("diffview.config")

local eq, neq = helpers.eq, helpers.neq
local formatters = require("diffview.scene.views.file_history.render").commit_formatters

-- Windows path standards:
-- https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats

describe("diffview.scenes.views.file_history.render.formatters", function()
  local renderer = require("diffview.renderer")

  it("status()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.status(comp, { status = "M" }, {})
    comp:ln()
    eq("M", comp.lines[1])

    comp:clear()
    formatters.status(comp, { status = nil }, {})
    comp:ln()
    eq("-", comp.lines[1])

    comp:destroy()
  end)

  it("files()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.files(comp, { single_file = false, files = { "a file" } }, { max_num_files = 1 })
    comp:ln()
    eq(" 1 file ", comp.lines[1])
    eq("DiffviewFilePanelCounter", comp.hl[1].group)

    comp:clear()
    formatters.files(
      comp,
      { nulled = true, single_file = false, files = { "a file" } },
      { max_num_files = 1 }
    )
    comp:ln()
    eq(" empty  ", comp.lines[1])

    comp:clear()
    formatters.files(comp, { single_file = true }, {})
    comp:ln()
    eq("", comp.lines[1])

    comp:destroy()
  end)

  it("hash()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.hash(
      comp,
      { commit = { hash = "762489b5c8d74bf8bbfb211d49aed686" } },
      { max_num_files = 1 }
    )
    comp:ln()
    eq(" 762489b5", comp.lines[1])
    eq("DiffviewHash", comp.hl[1].group)

    comp:destroy()
  end)

  it("stats()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.stats(comp, { stats = { additions = 10, deletions = 22 } }, { max_len_stats = 4 })
    comp:ln()
    eq(" | 1022 |", comp.lines[1])
    eq("DiffviewNonText", comp.hl[1].group)
    eq("DiffviewFilePanelInsertions", comp.hl[2].group)
    eq("DiffviewFilePanelDeletions", comp.hl[3].group)
    eq("DiffviewNonText", comp.hl[4].group)

    comp:destroy()
  end)

  it("reflog()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.reflog(comp, { commit = { reflog_selector = "reflog" } }, {})
    comp:ln()
    eq(" reflog", comp.lines[1])
    eq("DiffviewReflogSelector", comp.hl[1].group)

    comp:destroy()
  end)

  it("ref()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.ref(comp, { commit = { ref_names = "main" } }, {})
    comp:ln()
    eq(" (main)", comp.lines[1])
    eq("DiffviewReference", comp.hl[1].group)

    comp:destroy()
  end)

  it("subject()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.subject(
      comp,
      { commit = { subject = "refactor: cleanup" } },
      { panel = { cur_item = { nil } } }
    )
    comp:ln()
    eq(" refactor: cleanup", comp.lines[1])
    eq("DiffviewFilePanelFileName", comp.hl[1].group)

    comp:clear()
    formatters.subject(comp, { commit = { subject = "" } }, { panel = { cur_item = { nil } } })
    comp:ln()
    eq(" [empty message]", comp.lines[1])
    eq("DiffviewFilePanelFileName", comp.hl[1].group)

    comp:clear()
    local entry = { commit = { subject = "fix #1111" } }
    formatters.subject(comp, entry, { panel = { cur_item = { entry } } })
    comp:ln()
    eq(" fix #1111", comp.lines[1])
    eq("DiffviewFilePanelSelected", comp.hl[1].group)

    comp:destroy()
  end)

  it("author()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    formatters.author(comp, { commit = { author = "Dale Cooper" } }, {})
    comp:ln()
    eq(" Dale Cooper", comp.lines[1])

    comp:destroy()
  end)

  it("date()", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    local time = os.time({ year = 2023, month = 1, day = 1 })
    local iso = os.date("%FT%TZ", time)
    formatters.date(comp, { commit = { time = time, iso_date = iso } }, {})
    comp:ln()
    eq(" " .. iso, comp.lines[1])

    comp:destroy()
  end)

  it("default config format", function()
    --- @type RenderComponent
    local comp = renderer.RenderComponent.create_static_component(nil)
    local c = config.get_config()
    local time = os.time({ year = 2023, month = 1, day = 1 })
    local iso = os.date("%FT%TZ", time)
    local entry = {
      stats = { additions = 121, deletions = 101 },
      status = "M",
      commit = {
        time = time,
        iso_date = iso,
        hash = "ba89b7310101",
        subject = "fix #1",
        author = "Dale Cooper",
      },
    }

    local params = {
      panel = { cur_item = { nil } },
      max_num_files = 1,
      max_len_stats = 7,
    }

    for _, f in ipairs(c.file_history_panel.commit_format) do
      formatters[f](comp, entry, params)
    end

    comp:ln()
    local expected = string.format("M | 121 101 | ba89b731 fix #1 Dale Cooper %s", iso)
    eq(expected, table.concat(comp.lines, " "))

    comp:destroy()
  end)
end)
