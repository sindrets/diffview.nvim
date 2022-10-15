local oop = require('diffview.oop')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

local M = {}

local GitAdapter = oop.create_class('GitAdapter', VCSAdapter)

M.GitAdapter = GitAdapter
return M
