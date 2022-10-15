local oop = require('diffview.oop')
local logger = require('diffview.logger')
local utils = require('diffview.utils')
local config = require('diffview.config')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

local M = {}

local GitAdapter = oop.create_class('GitAdapter', VCSAdapter)

function GitAdapter:init(path)
  self.super:init(path)

  self.bootstrap.version_string = nil
  self.bootstrap.version = {}
  self.bootstrap.target_version_string = nil
  self.bootstrap.target_version = {
    major = 2,
    minor = 31,
    patch = 0,
  }

  self.context = self:get_context(path)
end

function GitAdapter:run_bootstrap()
  local msg
  self.bootstrap.done = true

  local out, code = utils.system_list(vim.tbl_flatten({ config.get_config().git_cmd, "version" }))
  if code ~= 0 or not out[1] then
    msg = "Could not run `git_cmd`!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  self.bootstrap.version_string = out[1]:match("git version (%S+)")

  if not self.bootstrap.version_string then
    msg = "Could not get git version!"
    logger.error(msg)
    utils.err(msg)
    return
  end

  -- Parse git version
  local v, target = self.bootstrap.version, self.bootstrap.target_version
  self.bootstrap.target_version_string = ("%d.%d.%d"):format(target.major, target.minor, target.patch)
  local parts = vim.split(self.bootstrap.version_string, "%.")
  v.major = tonumber(parts[1])
  v.minor = tonumber(parts[2])
  v.patch = tonumber(parts[3]) or 0

  local vs = ("%08d%08d%08d"):format(v.major, v.minor, v.patch)
  local ts = ("%08d%08d%08d"):format(target.major, target.minor, target.patch)

  if vs < ts then
    msg = (
      "Git version is outdated! Some functionality might not work as expected, "
      .. "or not at all! Target: %s, current: %s"
    ):format(
      self.bootstrap.target_version_string,
      self.bootstrap.version_string
    )
    logger.error(msg)
    utils.err(msg)
    return
  end

  self.bootstrap.ok = true
end

function GitAdapter:get_command()
  return config.get_config().git_cmd
end

function GitAdapter:get_context(path)
  local context = {}
  local out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--show-toplevel" }, path)
  if code ~= 0 then
    return nil
  end
  context.toplevel = out[1] and vim.trim(out[1])

  out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--git-dir" }, path)
  if code ~= 0 then
    return nil
  end
  context.dir = out[1] and vim.trim(out[1])
  return context
end

M.GitAdapter = GitAdapter
return M
