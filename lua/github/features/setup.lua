local M = {}
local config = require("github.core.config")
local defaults = { group_by = "Status", column_width = 36, max_items = 1000 }

local function validate_integer(value, default, minimum, maximum, name)
  if value == nil then
    return default
  end
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
    error("github.nvim setup projects." .. name .. " must be an integer between " .. minimum .. " and " .. maximum, 3)
  end
  return value
end

local function validate_projects(projects)
  if type(projects) ~= "table" then
    error("github.nvim setup projects must be a table", 3)
  end
  for key in pairs(projects) do
    if key ~= "group_by" and key ~= "column_width" and key ~= "max_items" then
      error("github.nvim setup does not support projects option: " .. tostring(key), 3)
    end
  end
  local group_by = projects.group_by
  if group_by == nil then
    group_by = defaults.group_by
  elseif type(group_by) ~= "string" then
    error("github.nvim setup projects.group_by must be a string", 3)
  else
    group_by = group_by:match("^%s*(.-)%s*$")
    if #group_by == 0 then
      error("github.nvim setup projects.group_by must not be empty", 3)
    end
  end
  return {
    group_by = group_by,
    column_width = validate_integer(projects.column_width, defaults.column_width, 20, 80, "column_width"),
    max_items = validate_integer(projects.max_items, defaults.max_items, 1, 10000, "max_items"),
  }
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("github.nvim setup expects a table or nil", 2)
  end
  local projects
  if opts then
    for key in pairs(opts) do
      if key ~= "projects" then
        error("github.nvim setup does not support option: " .. tostring(key), 2)
      end
    end
    projects = opts.projects
  end
  if projects == nil then
    projects = {}
  end
  config.set(validate_projects(projects))
  return {}
end

return M
