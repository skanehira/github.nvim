local M = {}

local config = require("github.core.config")

local LABEL_WIDTH = 12
local EMPTY = "—"
local LEFT_CAP = "\u{E0B6}"
local RIGHT_CAP = "\u{E0B4}"
local ENTRY_SEP = ", "
local PROJECT_SEP = "  ·  "

local function sanitize(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%c", " "))
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function prefix(label)
  return label .. string.rep(" ", math.max(LABEL_WIDTH - display_width(label), 0))
end

local function status_field(item)
  local values = type(item.fieldValues) == "table" and item.fieldValues.nodes
  if type(values) ~= "table" then
    return nil
  end
  local group_by = config.projects().group_by
  for _, value in ipairs(values) do
    local field = type(value) == "table" and value.field
    local name = type(field) == "table" and sanitize(field.name) or ""
    local value_name = type(value) == "table" and sanitize(value.name) or ""
    if name ~= "" and name:lower() == group_by:lower() and value_name ~= "" then
      return name, value_name
    end
  end
  return nil
end

function M.status(item)
  return status_field(item)
end

local function value_of(line, label)
  if type(line) ~= "string" then
    return nil, "restore the " .. label .. " header line"
  end
  local value = line:match("^" .. label .. "%s+(.*)$")
  if not value then
    return nil, "restore the " .. label .. " header line"
  end
  return value
end

local function split_entries(value)
  if value == EMPTY then
    return {}
  end
  local entries = {}
  for _, part in ipairs(vim.split(value, ",", { plain = true })) do
    part = vim.trim(part)
    if part ~= "" and part ~= EMPTY then
      entries[#entries + 1] = part
    end
  end
  return entries
end

local function parse_assignees(value)
  local logins = {}
  for _, part in ipairs(split_entries(value)) do
    local login = vim.trim((part:gsub("^@", "")))
    if login ~= "" then
      logins[#logins + 1] = login
    end
  end
  return logins
end

local function parse_labels(value)
  local names = {}
  for _, part in ipairs(split_entries(value)) do
    local name = vim.trim((part:gsub(LEFT_CAP, ""):gsub(RIGHT_CAP, "")))
    if name ~= "" then
      names[#names + 1] = name
    end
  end
  return names
end

local function parse_projects(value)
  local projects = {}
  for _, part in ipairs(split_entries(value)) do
    local title, rest = part:match("^(.-)%s*·%s*(.*)$")
    if title and vim.trim(title) ~= "" then
      local project = { title = vim.trim(title) }
      local field, status = rest:match("^([^:]+):%s*(.*)$")
      if field then
        project.field = vim.trim(field)
        project.status = vim.trim(status)
      end
      projects[#projects + 1] = project
    else
      projects[#projects + 1] = { title = vim.trim(part) }
    end
  end
  return projects
end

function M.lines(issue)
  local assignees = {}
  for _, node in ipairs((type(issue.assignees) == "table" and issue.assignees.nodes) or {}) do
    local login = sanitize(type(node) == "table" and node.login or "")
    if login ~= "" then
      assignees[#assignees + 1] = "@" .. login
    end
  end
  local labels = {}
  for _, node in ipairs((type(issue.labels) == "table" and issue.labels.nodes) or {}) do
    local name = sanitize(type(node) == "table" and node.name or "")
    if name ~= "" then
      labels[#labels + 1] = LEFT_CAP .. name .. RIGHT_CAP
    end
  end
  local projects = {}
  for _, item in ipairs((type(issue.projectItems) == "table" and issue.projectItems.nodes) or {}) do
    local project = type(item) == "table" and item.project
    local title = type(project) == "table" and sanitize(project.title) or ""
    if title ~= "" then
      local field_name, value = status_field(item)
      if field_name and value then
        projects[#projects + 1] = title .. PROJECT_SEP .. field_name .. ": " .. value
      else
        projects[#projects + 1] = title
      end
    end
  end
  local function value(entries)
    if #entries == 0 then
      return EMPTY
    end
    return table.concat(entries, ENTRY_SEP)
  end
  return {
    prefix("Assignees") .. value(assignees),
    prefix("Labels") .. value(labels),
    prefix("Projects") .. value(projects),
  }
end

function M.parse(lines)
  if type(lines) ~= "table" or #lines < 4 then
    return nil, "restore the issue header lines"
  end
  local assignees_value, assignees_err = value_of(lines[2], "Assignees")
  if not assignees_value then
    return nil, assignees_err
  end
  local labels_value, labels_err = value_of(lines[3], "Labels")
  if not labels_value then
    return nil, labels_err
  end
  local projects_value, projects_err = value_of(lines[4], "Projects")
  if not projects_value then
    return nil, projects_err
  end
  local body = {}
  for i = 5, #lines do
    body[#body + 1] = lines[i]
  end
  return {
    title = lines[1] or "",
    assignees = parse_assignees(assignees_value),
    labels = parse_labels(labels_value),
    projects = parse_projects(projects_value),
    body = table.concat(body, "\n"),
  }
end

local function add_span(spans, line, start_col, end_col, group)
  if start_col and end_col and end_col > start_col then
    spans[#spans + 1] = { line, start_col, end_col, group }
  end
end

local function label_groups(issue)
  local groups = {}
  for _, node in ipairs((type(issue.labels) == "table" and issue.labels.nodes) or {}) do
    if type(node) == "table" and type(node.name) == "string" and node.name ~= "" then
      local color = type(node.color) == "string" and node.color or ""
      groups[node.name] = {
        label = "GitHubIssueLabel",
        cap = "GitHubIssueLabelCap",
        color = color,
      }
    end
  end
  return groups
end

local function label_group_for(color)
  local hex = type(color) == "string" and color:gsub("^#", ""):lower() or ""
  if not hex:match("^%x%x%x%x%x%x$") then
    return "GitHubIssueLabel", "GitHubIssueLabelCap"
  end
  local function luminance()
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
  end
  local label_name = "GitHubIssueLabel_" .. hex
  if vim.fn.hlexists(label_name) == 0 then
    local fg = luminance() > 0.55 and "#0d1117" or "#ffffff"
    vim.api.nvim_set_hl(0, label_name, { bg = "#" .. hex, fg = fg, default = true })
  end
  local cap_name = "GitHubIssueLabelCap_" .. hex
  if vim.fn.hlexists(cap_name) == 0 then
    vim.api.nvim_set_hl(0, cap_name, { fg = "#" .. hex, default = true })
  end
  return label_name, cap_name
end

function M.spans(lines, issue)
  local spans = {}
  local groups = label_groups(issue)
  local assignee_line = lines[2] or ""
  local label_line = lines[3] or ""
  local project_line = lines[4] or ""
  add_span(spans, 1, 0, math.min(#prefix("Assignees"), #assignee_line), "gh_issue_meta")
  add_span(spans, 2, 0, math.min(#prefix("Labels"), #label_line), "gh_issue_meta")
  add_span(spans, 3, 0, math.min(#prefix("Projects"), #project_line), "gh_issue_meta")

  local parsed = M.parse(lines)
  if parsed then
    for _, login in ipairs(parsed.assignees) do
      local needle = "@" .. login
      local start_col = assignee_line:find(needle, 1, true)
      if start_col then
        add_span(spans, 1, start_col - 1, start_col - 1 + #needle, "gh_issue_user")
      end
    end
    for _, name in ipairs(parsed.labels) do
      local known = groups[name]
      local label_group, cap_group = label_group_for(known and known.color or "")
      local needle = LEFT_CAP .. name .. RIGHT_CAP
      local start_col = label_line:find(needle, 1, true)
      if start_col then
        local base = start_col - 1
        add_span(spans, 2, base, base + #LEFT_CAP, cap_group)
        add_span(spans, 2, base + #LEFT_CAP, base + #LEFT_CAP + #name, label_group)
        add_span(spans, 2, base + #LEFT_CAP + #name, base + #LEFT_CAP + #name + #RIGHT_CAP, cap_group)
      else
        local name_col = label_line:find(name, 1, true)
        if name_col then
          add_span(spans, 2, name_col - 1, name_col - 1 + #name, label_group)
        end
      end
    end
    for _, project in ipairs(parsed.projects) do
      local start_col = project_line:find(project.title, 1, true)
      if start_col then
        local base = start_col - 1
        add_span(spans, 3, base, base + #project.title, "gh_issue_project")
        local sep_col = project_line:find(PROJECT_SEP, base + #project.title, true)
        if sep_col then
          local field = project.field and project.field .. ": " or ""
          add_span(spans, 3, sep_col - 1, sep_col - 1 + #PROJECT_SEP + #field, "gh_issue_meta")
        end
      end
    end
  end
  return spans
end

return M
