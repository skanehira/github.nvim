local M = {}

local fields = require("github.features.issues.fields")

local LEFT_CAP = "\u{E0B6}"

local function value_start(line)
  local _, pos = line:find("^%s*%a+%s+()")
  return pos and pos - 1 or nil
end

local function skip_spaces(line, start)
  while line:sub(start + 1, start + 1) == " " do
    start = start + 1
  end
  return start
end

local function entry_start(line, col)
  local prefix = line:sub(1, col)
  local comma = prefix:match(".*,()")
  local start = comma and comma - 1 or value_start(line)
  if not start then
    return nil
  end
  return skip_spaces(line, start)
end

local function analyze(line, line_index, col)
  if line_index == 1 then
    local start = entry_start(line, col)
    if not start then
      return nil
    end
    return "assignees", start
  elseif line_index == 2 then
    local start = entry_start(line, col)
    if not start then
      return nil
    end
    if line:sub(start + 1, start + #LEFT_CAP) == LEFT_CAP then
      start = start + #LEFT_CAP
    end
    return "labels", start
  elseif line_index == 3 then
    local start = entry_start(line, col)
    if not start then
      return nil
    end
    local dot = line:sub(start + 1, col):find("·", 1, true)
    if not dot then
      return "projects", start
    end
    local dot_abs = start + dot
    local rest = skip_spaces(line, dot_abs + 1)
    local colon = line:sub(rest + 1, col):find(":", 1, true)
    if not colon then
      return nil
    end
    local field = vim.trim(line:sub(rest + 1, rest + colon - 1))
    local value = skip_spaces(line, rest + colon)
    local title = vim.trim(line:sub(start + 1, dot_abs - 1))
    return "status", value, title, field
  end
  return nil
end

local function find_project(issue, title)
  for _, item in ipairs((type(issue.projectItems) == "table" and issue.projectItems.nodes) or {}) do
    local project = type(item) == "table" and item.project
    if type(project) == "table" and project.title == title then
      return item
    end
  end
end

local function filter_matches(items, base, word, filter_word, menu, strip)
  local needle = strip(base):lower()
  local matches = {}
  for _, item in ipairs(items) do
    local filter_text = filter_word(item)
    if filter_text and filter_text:lower():sub(1, #needle) == needle then
      matches[#matches + 1] = { word = word(item), menu = menu }
    end
  end
  return matches
end

local function finish(buf, line_index, start, matches_for)
  if vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  if vim.api.nvim_win_get_cursor(0)[1] - 1 ~= line_index then
    return
  end
  if vim.fn.mode():sub(1, 1) ~= "i" then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, line_index, line_index + 1, false)[1] or ""
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
  local matches = matches_for(line:sub(start + 1, cursor_col))
  if #matches == 0 then
    return
  end
  vim.fn.complete(start + 1, matches)
end

function M.omnifunc(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  local state = require("github.features.issues.edit").state(buf)
  local line_index = vim.api.nvim_win_get_cursor(0)[1] - 1
  if not state or line_index < 1 or line_index > 3 then
    return findstart == 1 and -3 or {}
  end
  local line = vim.api.nvim_buf_get_lines(buf, line_index, line_index + 1, false)[1] or ""
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local kind, start, project_title, field_name = analyze(line, line_index, col)
  if not kind or not start then
    return findstart == 1 and -3 or {}
  end
  if findstart == 1 then
    return start
  end
  local target = state.target
  local function strip(text)
    if kind == "assignees" then
      return (text:gsub("^@", ""))
    end
    return text
  end
  -- Cached candidates make the fields callback run synchronously inside this
  -- omnifunc, where textlock turns vim.fn.complete() into E565. Return those
  -- matches instead; only candidates arriving later go through complete().
  local running, sync_matches = true, nil
  local function deliver(items, word, filter_word, menu)
    local function matches_for(text)
      return filter_matches(items, text, word, filter_word, menu, strip)
    end
    if running then
      sync_matches = matches_for(base)
      return
    end
    finish(buf, line_index, start, matches_for)
  end
  local function by_name(item)
    return item.name
  end
  local function by_title(item)
    return item.title
  end
  if kind == "assignees" then
    fields.assignable_users(target, function(items)
      if not items then
        return
      end
      deliver(items, function(item)
        return "@" .. item.login
      end, function(item)
        return item.login
      end, "assignee")
    end)
  elseif kind == "labels" then
    fields.labels(target, function(items)
      if not items then
        return
      end
      deliver(items, by_name, by_name, "label")
    end)
  elseif kind == "projects" then
    fields.projects(target, function(items)
      if not items then
        return
      end
      deliver(items, by_title, by_title, "project")
    end)
  elseif kind == "status" then
    local function complete_options(project_id)
      fields.project_fields(target, project_id, function(items)
        if not items then
          return
        end
        local field
        for _, item in ipairs(items) do
          if item.name:lower() == field_name:lower() then
            field = item
            break
          end
        end
        if not field then
          return
        end
        deliver(field.options, by_name, by_name, "status")
      end)
    end
    local current = find_project(state.issue, project_title)
    if current then
      complete_options(current.project.id)
    else
      fields.projects(target, function(items)
        if not items then
          return
        end
        for _, item in ipairs(items) do
          if item.title == project_title then
            return complete_options(item.id)
          end
        end
      end)
    end
  end
  running = false
  return sync_matches or {}
end

return M
