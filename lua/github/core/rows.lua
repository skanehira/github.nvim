local M = {}

local function single_line(text)
  return (text:gsub("\r\n", " "):gsub("[\r\n\t]", " "))
end

local function title(text)
  text = single_line(text)
  if vim.fn.strdisplaywidth(text) <= 100 then
    return text
  end
  local result = ""
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if vim.fn.strdisplaywidth(result .. char) > 100 then
      break
    end
    result = result .. char
  end
  return result .. "..."
end

local function align(rows, groups, selected)
  local widths, lines, spans = {}, {}, {}
  for _, row in ipairs(rows) do
    for column, text in ipairs(row) do
      widths[column] = math.max(widths[column] or 0, vim.fn.strdisplaywidth(text))
    end
  end
  for i, row in ipairs(rows) do
    local prefix = selected and selected[i] and "* " or "  "
    if prefix == "* " then
      spans[#spans + 1] = { i - 1, 0, 1, "gh_select" }
    end
    local line = prefix
    for column, text in ipairs(row) do
      local group = groups[i][column]
      if group and text ~= "" then
        spans[#spans + 1] = { i - 1, #line, #line + #text, group }
      end
      line = line .. text
      if column < #row then
        line = line .. string.rep(" ", widths[column] - vim.fn.strdisplaywidth(text) + 1)
      end
    end
    lines[i] = line
  end
  return lines, spans
end

function M.issues(items, selected)
  if #items == 0 then
    return { "0 issues" }, {}
  end
  local rows, groups = {}, {}
  for i, item in ipairs(items) do
    local assignees, labels = {}, {}
    for j = 1, math.min(2, #item.assignees.nodes) do
      assignees[j] = "@" .. single_line(item.assignees.nodes[j].login)
    end
    for j = 1, math.min(3, #item.labels.nodes) do
      labels[j] = single_line(item.labels.nodes[j].name)
    end
    rows[i] = {
      "#" .. item.number,
      title(item.title),
      item.state,
      table.concat(assignees, " "),
      "(" .. table.concat(labels, ", ") .. ")",
      " " .. item.comments.totalCount,
    }
    groups[i] = {
      [1] = "gh_issue_number",
      [3] = item.state == "CLOSED" and "gh_issue_closed" or "gh_issue_open",
      [4] = "gh_issue_user",
      [5] = "gh_issue_labels",
    }
  end
  return align(rows, groups, selected)
end

function M.comments(items, selected)
  if #items == 0 then
    return { "0 comments" }, {}
  end
  local rows, groups = {}, {}
  for i, item in ipairs(items) do
    local login = type(item.user) == "table" and item.user.login
    local author = login and ("@" .. single_line(login)) or "[deleted]"
    local body = type(item.body) == "string" and item.body or ""
    local first = body:gsub("\r\n", "\n"):match("^[^\n]*")
    rows[i] = { author, single_line(first) }
    groups[i] = { [1] = login and "gh_issue_comment_user" or nil }
  end
  return align(rows, groups, selected)
end

return M
