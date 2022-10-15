local oop = require('diffview.oop')
local VCSAdapter = require('diffview.vcs.adapter').VCSAdapter

local M = {}

local HgAdapter = oop.create_class('HgAdapter', VCSAdapter)

M.HgAdapter = HgAdapter
return M
