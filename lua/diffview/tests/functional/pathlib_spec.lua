local helpers = require("diffview.tests.helpers")

local eq, neq = helpers.eq, helpers.neq

-- Windows path standards:
-- https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats

describe("diffview.path", function()
  local PathLib = require("diffview.path").PathLib

  describe("convert()", function()
    it("converts to the default sep when non is specified", function()
      local pl = PathLib({ os = "unix" })

      eq("/foo/bar/baz", pl:convert("/foo/bar/baz"))
      eq("/foo/bar/baz", pl:convert([[\foo\bar\baz]]))
      eq("/foo/bar/baz", pl:convert("////foo///bar//baz"))
      eq("/foo/bar/baz", pl:convert([[\\\\foo\\//\bar\\baz]]))

      pl = PathLib({ os = "windows" })

      eq([[C:\foo\bar\baz]], pl:convert([[C:\foo\bar\baz]]))
      eq([[C:\foo\bar\baz]], pl:convert([[C:/foo/bar/baz]]))
      eq([[C:\foo\bar\baz]], pl:convert([[C:\\\\foo\\\bar\\baz]]))
      eq([[C:\foo\bar\baz]], pl:convert([[C:/foo//\\//bar//baz]]))
      eq([[\foo\bar\baz]], pl:convert([[\foo\bar\baz]]))
      eq([[\foo\bar\baz]], pl:convert([[/foo/bar/baz]]))

      -- Windows UNC paths
      eq([[\\wsl.localhost\foo\bar\baz]], pl:convert([[\\wsl.localhost\foo\bar\baz]]))
      eq([[\\wsl.localhost\foo\bar\baz]], pl:convert([[\\wsl.localhost/foo/bar/baz]]))
      eq([[\\]], pl:convert([[\\]]))

      -- Windows DOS Device paths
      eq([[\\.\foo\bar\baz]], pl:convert([[\\.\foo\bar\baz]]))
      eq([[\\.\foo\bar\baz]], pl:convert([[\\.\foo/bar/baz]]))
      eq([[\\.\]], pl:convert([[\\.\]]))

      eq([[\\?\foo\bar\baz]], pl:convert([[\\?\foo\bar\baz]]))
      eq([[\\?\foo\bar\baz]], pl:convert([[\\?\foo/bar/baz]]))
      eq([[\\?\]], pl:convert([[\\?\]]))
    end)

    it("converts to the specified sep", function()
      local pl = PathLib({ os = "unix" })

      eq([[/foo/bar/baz]], pl:convert([[/foo/bar/baz]], "/"))
      eq([[/foo/bar/baz]], pl:convert([[\foo\bar\baz]], "/"))
      eq([[\foo\bar\baz]], pl:convert([[/foo/bar/baz]], "\\"))
      eq([[\foo\bar\baz]], pl:convert([[\foo\bar\baz]], "\\"))

      pl = PathLib({ os = "windows" })

      eq([[C:\foo\bar\baz]], pl:convert([[C:\foo\bar\baz]], "\\"))
      eq([[C:\foo\bar\baz]], pl:convert([[C:/foo/bar/baz]], "\\"))
      eq([[C:/foo/bar/baz]], pl:convert([[C:\foo\bar\baz]], "/"))
      eq([[C:/foo/bar/baz]], pl:convert([[C:/foo/bar/baz]], "/"))

      -- UNC
      eq([[\\wsl.localhost\foo\bar\baz]], pl:convert([[\\wsl.localhost\foo\bar\baz]], "\\"))
      eq([[\\wsl.localhost\foo\bar\baz]], pl:convert([[//wsl.localhost/foo/bar/baz]], "\\"))
      eq([[//wsl.localhost/foo/bar/baz]], pl:convert([[\\wsl.localhost\foo\bar\baz]], "/"))
      eq([[//wsl.localhost/foo/bar/baz]], pl:convert([[//wsl.localhost/foo/bar/baz]], "/"))

      -- DOS Device
      eq([[\\.\foo\bar\baz]], pl:convert([[\\.\foo\bar\baz]], "\\"))
      eq([[\\.\foo\bar\baz]], pl:convert([[//./foo/bar/baz]], "\\"))
      eq([[//./foo/bar/baz]], pl:convert([[\\.\foo\bar\baz]], "/"))
      eq([[//./foo/bar/baz]], pl:convert([[//./foo/bar/baz]], "/"))

      eq([[\\?\foo\bar\baz]], pl:convert([[\\?\foo\bar\baz]], "\\"))
      eq([[\\?\foo\bar\baz]], pl:convert([[//?/foo/bar/baz]], "\\"))
      eq([[//?/foo/bar/baz]], pl:convert([[\\?\foo\bar\baz]], "/"))
      eq([[//?/foo/bar/baz]], pl:convert([[//?/foo/bar/baz]], "/"))
    end)

    it("handles URI's correctly", function()
      local pl = PathLib({ os = "unix" })

      eq("test:///foo/bar/baz", pl:convert("test:///foo/bar/baz"))
      eq("test://foo/bar/baz", pl:convert("test://foo/bar/baz"))
      eq("test:///foo/bar/baz", pl:convert([[test://\foo\bar\baz]]))

      pl = PathLib({ os = "windows" })

      eq("test:///foo/bar/baz", pl:convert("test:///foo/bar/baz"))
      eq("test://foo/bar/baz", pl:convert("test://foo/bar/baz"))
      eq("test:///foo/bar/baz", pl:convert([[test://\foo\bar\baz]]))
    end)
  end)

  describe("is_abs()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq(true, pl:is_abs("/foo/bar/baz"))
      eq(true, pl:is_abs("/"))
      eq(false, pl:is_abs("foo/bar/baz"))
      eq(false, pl:is_abs(""))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      -- fs
      eq(true, pl:is_abs("C:/foo/bar/baz"))
      eq(true, pl:is_abs("C:/"))
      eq(true, pl:is_abs("/"))
      eq(false, pl:is_abs("foo/bar/baz"))
      eq(false, pl:is_abs(""))

      -- UNC
      eq(true, pl:is_abs([[\\wsl.localhost\Ubuntu1804]]))
      eq(true, pl:is_abs([[\\]]))

      -- DOS Device
      eq(true, pl:is_abs([[\\.\foo\bar\baz]]))
      eq(true, pl:is_abs([[\\.\]]))

      eq(true, pl:is_abs([[\\?\foo\bar\baz]]))
      eq(true, pl:is_abs([[\\?\]]))
    end)
  end)

  describe("absolute()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq([[/foo/bar/baz]], pl:absolute([[bar/baz]], [[/foo]]))
      eq([[/foo/bar/baz]], pl:absolute([[/foo/bar/baz]], [[/foo]]))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      eq([[C:\foo\bar\baz]], pl:absolute([[bar\baz]], [[C:\foo]]))
      eq([[C:\foo\bar\baz]], pl:absolute([[C:\foo\bar\baz]], [[C:\foo]]))

      eq([[C:\foo\bar\baz]], pl:absolute([[\foo\bar\baz]], [[C:\lorem\ipsum]]))
      eq([[D:\foo\bar\baz]], pl:absolute([[\foo\bar\baz]], [[D:\lorem\ipsum]]))

      eq([[\\wsl.localhost\foo\bar\baz]], pl:absolute([[bar\baz]], [[\\wsl.localhost\foo]]))
      eq([[\\wsl.localhost\foo\bar\baz]], pl:absolute([[\\wsl.localhost\foo\bar\baz]], [[\\wsl.localhost\foo]]))

      eq([[\\.\foo\bar\baz]], pl:absolute([[bar\baz]], [[\\.\foo]]))
      eq([[\\.\foo\bar\baz]], pl:absolute([[\\.\foo\bar\baz]], [[\\.\foo]]))

      eq([[\\?\foo\bar\baz]], pl:absolute([[bar\baz]], [[\\?\foo]]))
      eq([[\\?\foo\bar\baz]], pl:absolute([[\\?\foo\bar\baz]], [[\\?\foo]]))
    end)
  end)

  describe("is_root()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq(true, pl:is_root("/"))
      eq(false, pl:is_root("/foo"))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      eq(true, pl:is_root([[C:\]]))
      eq(true, pl:is_root([[C:]]))
      eq(true, pl:is_root([[\]]))
      eq(false, pl:is_root([[C:\foo]]))

      eq(true, pl:is_root([[\\]]))
      eq(false, pl:is_root([[\\foo]]))

      eq(true, pl:is_root([[\\.\]]))
      eq(false, pl:is_root([[\\.\foo]]))

      eq(true, pl:is_root([[\\?\]]))
      eq(false, pl:is_root([[\\?\foo]]))
    end)
  end)

  describe("root()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq("/", pl:root("/"))
      eq("/", pl:root("/foo"))
      eq(nil, pl:root("foo/bar/baz"))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      eq(nil, pl:root([[foo\bar\baz]]))

      eq([[C:]], pl:root([[C:]]))
      eq([[C:]], pl:root([[C:\foo\bar\baz]]))
      eq([[\]], pl:root([[\]]))
      eq([[\]], pl:root([[\foo\bar\baz]]))

      eq([[\\]], pl:root([[\\]]))
      eq([[\\]], pl:root([[\\foo\bar\baz]]))

      eq([[\\.\]], pl:root([[\\.\]]))
      eq([[\\.\]], pl:root([[\\.\foo\bar\baz]]))

      eq([[\\?\]], pl:root([[\\?\]]))
      eq([[\\?\]], pl:root([[\\?\foo\bar\baz]]))
    end)
  end)

  describe("normalize()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq("foo/bar/baz", pl:normalize("foo/bar/././baz", { cwd = "/lorem/ipsum/dolor" }))
      eq("foo/baz", pl:normalize("foo/bar/../baz", { cwd = "/lorem/ipsum/dolor" }))
      eq("/lorem/ipsum/baz", pl:normalize("foo/../../baz", { cwd = "/lorem/ipsum/dolor" }))
      eq(".", pl:normalize("foo/..", { cwd = "/lorem/ipsum/dolor" }))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      -- Resolves relative drive
      eq([[D:\foo\bar\baz]], pl:normalize([[\foo\bar\baz]], { cwd = [[D:\lorem\ipsum\dolor]] }))
    end)
  end)

  describe("expand()", function()
    local save_env = {}

    before_each(function()
      local env = {
        HOME = "/lorem/ipsum/dolor",
        VAR_FOO = "EXPANDED_FOO",
        VAR_BAR = "EXPANDED_BAR",
      }
      for k, v in pairs(env) do
        save_env[k] = vim.env[k] or ""
        vim.env[k] = v
      end
    end)

    after_each(function()
      for k, v in pairs(save_env) do vim.env[k] = v end
    end)

    it("works", function()
      local pl = PathLib({ os = "unix" })

      eq("/lorem/ipsum/dolor/foo", pl:expand("~/foo"))
      eq("foo/EXPANDED_FOO/EXPANDED_BAR/baz", pl:expand("foo/$VAR_FOO/$VAR_BAR/baz"))
    end)
  end)

  describe("join()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq([[/foo/bar/baz]], pl:join({ "/", "foo", "bar", "baz" }))
      eq([[/foo/bar/baz]], pl:join({ "/foo/bar", "baz" }))
      eq([[/foo/bar/baz]], pl:join({ "/", "foo/", "/bar///", "/baz" }))
      eq([[foo/bar/baz]], pl:join({ "", "foo", "bar", "baz" }))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      eq([[C:\foo\bar\baz]], pl:join({ "C:", "foo", "bar", "baz" }))
      eq([[C:\foo\bar\baz]], pl:join({ "C:\\foo\\bar", "baz" }))
      eq([[C:\foo\bar\baz]], pl:join({ "C:\\", "foo\\", "\\bar\\\\", "\\baz" }))
      eq([[\foo\bar\baz]], pl:join({ "\\", "foo", "bar", "baz" }))
      eq([[foo\bar\baz]], pl:join({ "", "foo", "bar", "baz" }))

      eq([[\\foo\bar\baz]], pl:join({ [[\\]], "foo", "bar", "baz" }))
      eq([[\\foo\bar\baz]], pl:join({ [[\\foo\\bar]], "baz" }))
      eq([[\\foo\bar\baz]], pl:join({ [[\\]], "foo\\", "\\bar\\\\", "\\baz" }))

      eq([[\\.\foo\bar\baz]], pl:join({ [[\\.\]], "foo", "bar", "baz" }))
      eq([[\\.\foo\bar\baz]], pl:join({ [[\\.\foo\\bar]], "baz" }))
      eq([[\\.\foo\bar\baz]], pl:join({ [[\\.\]], "foo\\", "\\bar\\\\", "\\baz" }))

      eq([[\\?\foo\bar\baz]], pl:join({ [[\\?\]], "foo", "bar", "baz" }))
      eq([[\\?\foo\bar\baz]], pl:join({ [[\\?\foo\\bar]], "baz" }))
      eq([[\\?\foo\bar\baz]], pl:join({ [[\\?\]], "foo\\", "\\bar\\\\", "\\baz" }))
    end)

    it("works for URIs", function()
      local pl = PathLib({ os = "unix" })

      eq([[test:///foo/bar/baz]], pl:join({ "test://", "/", "foo", "bar", "baz"}))
      eq([[test://foo/bar/baz]], pl:join({ "test://", "foo", "bar", "baz"}))
      eq([[test://foo/bar/baz]], pl:join({ "test://", "foo/", "//bar/", "baz"}))
    end)
  end)

  describe("explode()", function()
    it("works for UNIX paths", function()
      local pl = PathLib({ os = "unix" })

      eq({ "/", "foo", "bar", "baz" }, pl:explode("/foo/bar/baz"))
      eq({ "foo", "bar", "baz" }, pl:explode("foo/bar/baz"))
    end)

    it("works for Windows paths", function()
      local pl = PathLib({ os = "windows" })

      eq({ "C:", "foo", "bar", "baz" }, pl:explode([[C:\foo\bar\baz]]))
      eq({ "foo", "bar", "baz" }, pl:explode([[foo\bar\baz]]))

      eq({ [[\]], "foo", "bar", "baz" }, pl:explode([[\foo\bar\baz]]))
      eq({ [[\\]], "foo", "bar", "baz" }, pl:explode([[\\foo\bar\baz]]))
      eq({ [[\\.\]], "foo", "bar", "baz" }, pl:explode([[\\.\foo\bar\baz]]))
      eq({ [[\\?\]], "foo", "bar", "baz" }, pl:explode([[\\?\foo\bar\baz]]))
    end)

    it("works for URIs", function()
      local pl = PathLib({ os = "unix" })

      eq({ "test://", "/", "foo", "bar", "baz" }, pl:explode("test:///foo/bar/baz"))
      eq({ "test://", "foo", "bar", "baz" }, pl:explode("test://foo/bar/baz"))
    end)
  end)
end)
