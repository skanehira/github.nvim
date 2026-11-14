local M = {}

local namespace = vim.api.nvim_create_namespace("github_issue_detail")
local states = {}
local attached = {}
local resized = false

local LABEL_WIDTH = 12
local ELLIPSIS = "..."
local LEFT_CAP = "\u{E0B6}"
local RIGHT_CAP = "\u{E0B4}"

local function sanitize(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%c", " "))
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + display_width(chunk[1])
  end
  return width
end

local function append(target, chunks)
  for _, chunk in ipairs(chunks) do
    target[#target + 1] = chunk
  end
end

local function wrap(text, width)
  local lines, current = {}, ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if display_width(current .. char) > width and current ~= "" then
      lines[#lines + 1] = current
      current = char
    else
      current = current .. char
    end
  end
  if current ~= "" then
    lines[#lines + 1] = current
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if display_width(text) <= width then
    return text
  end
  local budget = width - display_width(ELLIPSIS)
  if budget <= 0 then
    return ELLIPSIS
  end
  local result = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if display_width(result .. char) > budget then
      break
    end
    result = result .. char
  end
  return result .. ELLIPSIS
end

local function truncate_chunks(chunks, width)
  if chunks_width(chunks) <= width then
    return chunks
  end
  local result, used = {}, 0
  local budget = math.max(width - display_width(ELLIPSIS), 0)
  for _, chunk in ipairs(chunks) do
    local piece = ""
    for _, char in ipairs(vim.fn.split(chunk[1], "\\zs")) do
      local char_width = display_width(char)
      if used + char_width > budget then
        if piece ~= "" then
          result[#result + 1] = { piece, chunk[2] }
        end
        result[#result + 1] = { ELLIPSIS, chunk[2] }
        return result
      end
      piece = piece .. char
      used = used + char_width
    end
    if piece ~= "" then
      result[#result + 1] = { piece, chunk[2] }
    end
  end
  return result
end

local function luminance(hex)
  hex = hex:gsub("^#", "")
  if #hex ~= 6 or not hex:match("^%x%x%x%x%x%x$") then
    return 1
  end
  local r = tonumber(hex:sub(1, 2), 16)
  local g = tonumber(hex:sub(3, 4), 16)
  local b = tonumber(hex:sub(5, 6), 16)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

local function label_group(color)
  local hex = type(color) == "string" and color:gsub("^#", ""):lower() or ""
  if not hex:match("^%x%x%x%x%x%x$") then
    return "GitHubIssueLabel"
  end
  local name = "GitHubIssueLabel_" .. hex
  if vim.fn.hlexists(name) == 0 then
    local fg = luminance(hex) > 0.55 and "#0d1117" or "#ffffff"
    vim.api.nvim_set_hl(0, name, { bg = "#" .. hex, fg = fg, default = true })
  end
  return name
end

local function label_cap_group(color)
  local hex = type(color) == "string" and color:gsub("^#", ""):lower() or ""
  if not hex:match("^%x%x%x%x%x%x$") then
    return "GitHubIssueLabelCap"
  end
  local name = "GitHubIssueLabelCap_" .. hex
  if vim.fn.hlexists(name) == 0 then
    vim.api.nvim_set_hl(0, name, { fg = "#" .. hex, default = true })
  end
  return name
end

local function title_lines(issue, width)
  local text = sanitize(type(issue.title) == "string" and issue.title or "")
  local lines = wrap(text, width)
  local result = {}
  for _, line in ipairs(lines) do
    result[#result + 1] = { { line, "gh_issue_title" } }
  end
  return result
end

local function state_lines(issue, target, width)
  local closed = issue.state == "CLOSED"
  local state = closed and "Closed" or "Open"
  local group = closed and "gh_issue_state_closed" or "gh_issue_state_open"
  local left = {
    { "● ", group },
    { state, group },
    { "   ", nil },
    { "#" .. tostring(issue.number or target.issue_number), "gh_issue_number" },
  }
  local repo = target.owner .. "/" .. target.repo
  local left_width = chunks_width(left)
  local repo_width = display_width(repo)
  if left_width + 2 + repo_width <= width then
    left[#left + 1] = { string.rep(" ", width - left_width - repo_width), nil }
    left[#left + 1] = { repo, "gh_issue_meta" }
    return { left }
  end
  return { left, { { repo, "gh_issue_meta" } } }
end

local function assignee_items(issue)
  local items = {}
  local nodes = type(issue.assignees) == "table" and issue.assignees.nodes
  if type(nodes) ~= "table" then
    return items
  end
  for _, node in ipairs(nodes) do
    local login = sanitize(type(node) == "table" and node.login or "")
    if login ~= "" then
      items[#items + 1] = { { "@" .. login, "gh_issue_user" } }
    end
  end
  return items
end

local function label_items(issue)
  local labels = type(issue.labels) == "table" and issue.labels
  local nodes = labels and labels.nodes
  local total = tonumber(labels and labels.totalCount) or (type(nodes) == "table" and #nodes or 0)
  local items = {}
  if type(nodes) == "table" then
    for _, label in ipairs(nodes) do
      local name = sanitize(type(label) == "table" and label.name or "")
      if name ~= "" then
        local group = label_group(label.color)
        local cap = label_cap_group(label.color)
        items[#items + 1] = { { LEFT_CAP, cap }, { name, group }, { RIGHT_CAP, cap } }
      end
    end
  end
  return items, total
end

local function status_field(item)
  local values = type(item.fieldValues) == "table" and item.fieldValues.nodes
  if type(values) ~= "table" then
    return nil
  end
  for _, value in ipairs(values) do
    local field = type(value) == "table" and value.field
    local name = type(field) == "table" and sanitize(field.name) or ""
    local value_name = type(value) == "table" and sanitize(value.name) or ""
    if name ~= "" and name:lower() == "status" and value_name ~= "" then
      return name, value_name
    end
  end
  return nil
end

local function project_items(issue)
  local items = {}
  local nodes = type(issue.projectItems) == "table" and issue.projectItems.nodes
  if type(nodes) ~= "table" then
    return items
  end
  for _, item in ipairs(nodes) do
    local project = type(item) == "table" and item.project
    local title = type(project) == "table" and sanitize(project.title) or ""
    if title ~= "" then
      local field_name, value = status_field(item)
      items[#items + 1] = { title = title, field_name = field_name, value = value }
    end
  end
  return items
end

local function project_chunks(project, available)
  local suffix = ""
  if project.field_name and project.value then
    suffix = "  ·  " .. project.field_name .. ": " .. project.value
  end
  local title_width = available - display_width(suffix)
  if title_width < 1 then
    suffix = ""
    title_width = available
  end
  local chunks = { { truncate(project.title, title_width), "gh_issue_project" } }
  if suffix ~= "" then
    chunks[#chunks + 1] = { "  ·  ", "gh_issue_meta" }
    chunks[#chunks + 1] = { project.field_name .. ": ", "gh_issue_meta" }
    chunks[#chunks + 1] = { project.value, nil }
  end
  return chunks
end

local function project_lines(items, width)
  local available = math.max(width - LABEL_WIDTH, 1)
  if #items == 0 then
    return {
      {
        { "Projects" .. string.rep(" ", LABEL_WIDTH - display_width("Projects")), "gh_issue_meta" },
        { "—", "gh_issue_meta" },
      },
    }
  end
  local lines = {}
  for index, project in ipairs(items) do
    local prefix = index == 1 and "Projects" .. string.rep(" ", LABEL_WIDTH - display_width("Projects"))
      or string.rep(" ", LABEL_WIDTH)
    local line = { { prefix, "gh_issue_meta" } }
    append(line, project_chunks(project, available))
    lines[#lines + 1] = line
  end
  return lines
end

local function pack_items(items, width)
  local lines, current, used, placed = {}, {}, 0, 0
  for _, item in ipairs(items) do
    local item_width = chunks_width(item)
    local gap = used > 0 and 1 or 0
    if used + gap + item_width <= width then
      if gap > 0 then
        current[#current + 1] = { " ", nil }
      end
      append(current, item)
      used = used + gap + item_width
      placed = placed + 1
    else
      if #current > 0 then
        lines[#lines + 1] = current
      end
      current = {}
      append(current, item_width <= width and item or truncate_chunks(item, width))
      used = math.min(item_width, width)
      placed = placed + 1
    end
  end
  if #current > 0 then
    lines[#lines + 1] = current
  end
  return lines, placed
end

local function meta_lines(label, items, width, total)
  local available = math.max(width - LABEL_WIDTH, 1)
  local lines, placed = pack_items(items, available)
  if total and placed < total then
    local more = { { "+" .. tostring(total - placed), "gh_issue_meta" } }
    local last = lines[#lines]
    if last then
      local gap = chunks_width(last) > 0 and 1 or 0
      if chunks_width(last) + gap + chunks_width(more) <= available then
        if gap > 0 then
          last[#last + 1] = { " ", nil }
        end
        append(last, more)
      else
        lines[#lines + 1] = more
      end
    else
      lines[1] = more
    end
  end
  local result = {}
  for index, line in ipairs(lines) do
    local prefix = index == 1 and label .. string.rep(" ", LABEL_WIDTH - display_width(label))
      or string.rep(" ", LABEL_WIDTH)
    local chunks = { { prefix, "gh_issue_meta" } }
    append(chunks, line)
    result[#result + 1] = chunks
  end
  if #result == 0 then
    result[1] = {
      { label .. string.rep(" ", LABEL_WIDTH - display_width(label)), "gh_issue_meta" },
      { "—", "gh_issue_meta" },
    }
  end
  return result
end

local function build(issue, target, width)
  width = math.max(width, 20)
  local lines = {}
  append(lines, title_lines(issue, width))
  lines[#lines + 1] = {}
  append(lines, state_lines(issue, target, width))
  lines[#lines + 1] = {}
  append(lines, meta_lines("Assignees", assignee_items(issue), width))
  local labels, total = label_items(issue)
  append(lines, meta_lines("Labels", labels, width, total))
  append(lines, project_lines(project_items(issue), width))
  lines[#lines + 1] = { { string.rep("─", width), "gh_issue_separator" } }
  lines[#lines + 1] = {}
  return lines
end

local function buffer_width(buf)
  local widths = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    widths[#widths + 1] = vim.api.nvim_win_get_width(win)
  end
  if #widths == 0 then
    return 80
  end
  local width = widths[1]
  for _, candidate in ipairs(widths) do
    if candidate < width then
      width = candidate
    end
  end
  return width
end

local function apply(buf, issue, target)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local lines = build(issue, target, buffer_width(buf))
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    virt_lines = lines,
    virt_lines_above = true,
    priority = 100,
  })
end

local function ensure_resized()
  if resized then
    return
  end
  resized = true
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = vim.api.nvim_create_augroup("github_issue_detail_resize", { clear = true }),
    callback = function()
      for buf, state in pairs(states) do
        if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
          apply(buf, state.issue, state.target)
        end
      end
    end,
  })
end

local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  local group = vim.api.nvim_create_augroup("github_issue_detail_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.wo[win].wrap = true
      end
      local state = states[buf]
      if state then
        apply(buf, state.issue, state.target)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      states[buf] = nil
      attached[buf] = nil
    end,
  })
end

function M.render(buf, issue, target)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  ensure_resized()
  attach(buf)
  states[buf] = { issue = issue, target = target }
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].wrap = true
  end
  apply(buf, issue, target)
end

return M
