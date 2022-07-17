local oop = require("diffview.oop")

local M = {}

---@class Model : diffview.Object
local Model = oop.create_class("Model")

---@diagnostic disable unused-local

---@abstract
---@param data table
---@return CompSchema
function Model:create_comp_schema(data) oop.abstract_stub() end

---@abstract
---@param render_data RenderData
function Model:render(render_data) oop.abstract_stub() end

---@diagnostic enable unused-local

M.Model = Model
return M
