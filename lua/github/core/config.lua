local M = {}
local projects = { group_by = "Status", column_width = 36, max_items = 1000 }

function M.set(values)
  projects = {
    group_by = values.group_by,
    column_width = values.column_width,
    max_items = values.max_items,
  }
end

function M.projects()
  return {
    group_by = projects.group_by,
    column_width = projects.column_width,
    max_items = projects.max_items,
  }
end

return M
