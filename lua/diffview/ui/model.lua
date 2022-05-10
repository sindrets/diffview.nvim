local oop = require("diffview.oop")

local M = {}

---@class Model : Object
---@field create_comp_schema? fun(data: table): CompSchema
---@field render? fun(render_data: RenderData)
local Model = oop.create_class("Model")

Model:virtual("create_comp_schema")
Model:virtual("render")

M.Model = Model
return M
