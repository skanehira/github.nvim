local float = require("github.core.float")
local highlight = require("github.core.highlight")

local M = {}

local ELLIPSIS = "..."
local COLOR_GROUPS = {
  GRAY = "GitHubProjectsColorGray",
  RED = "GitHubProjectsColorRed",
  ORANGE = "GitHubProjectsColorOrange",
  YELLOW = "GitHubProjectsColorYellow",
  GREEN = "GitHubProjectsColorGreen",
  PINK = "GitHubProjectsColorPink",
  PURPLE = "GitHubProjectsColorPurple",
  BLUE = "GitHubProjectsColorBlue",
}

local function sanitize(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%c", " "))
end

local function push(lines, spans, text, width, selected, end_col, group)
  local value = M.truncate(text, width)
  local line = M.pad(value, width)
  lines[#lines + 1] = line
  local row = #lines - 1
  if selected then
    if #line > 0 then
      spans[#spans + 1] = { row, 0, #line, "GitHubProjectsCardSelected" }
    end
  elseif group and end_col and end_col > 0 then
    local stop = math.min(end_col, #value)
    if stop > 0 then
      spans[#spans + 1] = { row, 0, stop, group }
    end
  end
end

local function labels_text(content)
  local labels = content.labels
  if type(labels) ~= "table" or type(labels.nodes) ~= "table" or #labels.nodes == 0 then
    return nil
  end
  local names = {}
  for index, label in ipairs(labels.nodes) do
    if index > 2 then
      break
    end
    names[#names + 1] = sanitize(label.name)
  end
  local total = tonumber(labels.totalCount) or #labels.nodes
  if total > #names then
    names[#names + 1] = "+" .. (total - #names)
  end
  return "(" .. table.concat(names, ", ") .. ")"
end

local function assignees_text(content)
  local assignees = content.assignees
  if type(assignees) ~= "table" or type(assignees.nodes) ~= "table" or #assignees.nodes == 0 then
    return nil
  end
  local logins = {}
  for index, assignee in ipairs(assignees.nodes) do
    if index > 2 then
      break
    end
    logins[#logins + 1] = "@" .. sanitize(assignee.login)
  end
  local total = tonumber(assignees.totalCount) or #assignees.nodes
  if total > #logins then
    logins[#logins + 1] = "+" .. (total - #logins)
  end
  return table.concat(logins, " ")
end

local function meta_text(content)
  local labels = labels_text(content)
  local assignees = assignees_text(content)
  if labels and assignees then
    return labels .. " " .. assignees
  end
  return labels or assignees
end

local function progress_text(content, width)
  local summary = content.subIssuesSummary
  if type(summary) ~= "table" then
    return nil
  end
  local total = tonumber(summary.total) or 0
  if total <= 0 then
    return nil
  end
  local completed = math.max(0, math.min(total, tonumber(summary.completed) or 0))
  local bar_width = math.max(1, width - 10)
  local filled = math.floor(bar_width * completed / total)
  local percent = math.floor(completed * 100 / total)
  return string.format(
    "%d/%d %s%s %d%%",
    completed,
    total,
    string.rep("█", filled),
    string.rep("░", bar_width - filled),
    percent
  )
end

local function related_text(content)
  local references = content.closedByPullRequestsReferences
  if type(references) ~= "table" or type(references.nodes) ~= "table" then
    return nil
  end
  local numbers = {}
  for index, reference in ipairs(references.nodes) do
    if index > 2 then
      break
    end
    local number = tonumber(reference.number)
    if number then
      numbers[#numbers + 1] = "PR #" .. number
    end
  end
  if #numbers == 0 then
    return nil
  end
  local total = tonumber(references.totalCount) or #references.nodes
  if total > #numbers then
    numbers[#numbers + 1] = "+" .. (total - #numbers)
  end
  return table.concat(numbers, " ")
end

local function scroll_maps(win, buf)
  local function go(line)
    local count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(count, line)), 0 })
  end
  local function move(delta)
    go(vim.api.nvim_win_get_cursor(win)[1] + delta)
  end
  local function half()
    return math.max(1, math.floor(vim.api.nvim_win_get_config(win).height / 2))
  end
  return {
    j = function()
      move(vim.v.count1)
    end,
    k = function()
      move(-vim.v.count1)
    end,
    gg = function()
      go(vim.v.count > 0 and vim.v.count or 1)
    end,
    G = function()
      go(vim.v.count > 0 and vim.v.count or vim.api.nvim_buf_line_count(buf))
    end,
    ["<C-d>"] = function()
      move(half())
    end,
    ["<C-u>"] = function()
      move(-half())
    end,
  }
end

function M.truncate(text, width)
  text = sanitize(text)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local limit = width
  local suffix = ""
  if width >= #ELLIPSIS then
    limit = width - #ELLIPSIS
    suffix = ELLIPSIS
  end
  local result = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(result .. char) > limit then
      break
    end
    result = result .. char
  end
  return result .. suffix
end

function M.pad(text, width)
  local value = M.truncate(text, width)
  local padding = width - vim.fn.strdisplaywidth(value)
  if padding > 0 then
    value = value .. string.rep(" ", padding)
  end
  return value
end

function M.column_width(inner_width, configured)
  local width = math.max(20, math.min(80, configured or 36))
  return math.max(1, math.min(width, inner_width))
end

function M.visible_columns(inner_width, column_width)
  return math.max(1, math.floor((inner_width + 1) / (column_width + 1)))
end

function M.first_col(first, visible, selected, total)
  if selected < first then
    first = selected
  elseif selected > first + visible - 1 then
    first = selected - visible + 1
  end
  local last = math.max(1, total - visible + 1)
  return math.max(1, math.min(first, last))
end

function M.join(parts)
  local keys = {}
  for key in pairs(parts) do
    if type(key) == "number" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  local values = {}
  for _, key in ipairs(keys) do
    local part = parts[key]
    if part and part ~= "" then
      values[#values + 1] = part
    end
  end
  return table.concat(values, "  ·  ")
end

function M.header(state)
  local text, group
  if state.error then
    text, group = "Error: " .. sanitize(state.error), "GitHubProjectsError"
  elseif state.loading then
    text, group = sanitize(state.loading), "GitHubProjectsLoading"
  elseif state.truncated then
    text, group = sanitize(state.truncated), "GitHubProjectsHeader"
  else
    text, group = sanitize(state.text), "GitHubProjectsHeader"
  end
  if text == "" then
    return text, {}
  end
  return text, { { 0, 0, #text, group } }
end

function M.color_group(color)
  if type(color) ~= "string" then
    return nil
  end
  return COLOR_GROUPS[color:upper()]
end

function M.card(item, width, selected)
  local body = item and item.content
  if type(body) ~= "table" then
    body = nil
  end
  local item_type = item and item.type
  local lines, spans = {}, {}

  if body and item_type == "DRAFT_ISSUE" then
    local prefix = "✎"
    push(lines, spans, prefix .. " " .. sanitize(body.title), width, selected, #prefix, "GitHubProjectsNumber")
    return lines, spans
  end

  local number = body and tonumber(body.number)
  if body and number and (item_type == "ISSUE" or item_type == "PULL_REQUEST") then
    local prefix = (item_type == "ISSUE" and "○ #" or "⇄ #") .. number
    push(lines, spans, prefix .. " " .. sanitize(body.title), width, selected, #prefix, "GitHubProjectsNumber")
    local meta = meta_text(body)
    if meta then
      push(lines, spans, meta, width, selected, #meta, "GitHubProjectsMeta")
    end
    if item_type == "ISSUE" then
      local progress = progress_text(body, width)
      if progress then
        push(lines, spans, progress, width, selected, #progress, "GitHubProjectsProgress")
      end
      local related = related_text(body)
      if related then
        push(lines, spans, related, width, selected, #related, "GitHubProjectsMeta")
      end
    end
    return lines, spans
  end

  push(lines, spans, "[redacted]", width, selected, #"[redacted]", "GitHubProjectsRedacted")
  return lines, spans
end

function M.column_header(column, width, selected)
  local marker = column.no_value and "○" or "●"
  local name = column.no_value and "値なし" or sanitize(column.name)
  local value = M.truncate(marker .. " " .. name .. " " .. tostring(column.count or 0), width)
  local line = M.pad(value, width)
  local spans = {}

  if selected then
    if #value > 0 then
      spans[1] = { 0, 0, #value, "GitHubProjectsColumnSelected" }
    end
    return line, spans
  end

  local group = M.color_group(column.color)
  if group then
    local marker_end = math.min(#marker, #value)
    if marker_end > 0 then
      spans[#spans + 1] = { 0, 0, marker_end, group }
    end
    local rest_start = #marker + 1
    if rest_start < #value then
      spans[#spans + 1] = { 0, rest_start, #value, "GitHubProjectsColumn" }
    end
  elseif #value > 0 then
    spans[1] = { 0, 0, #value, "GitHubProjectsColumn" }
  end
  return line, spans
end

function M.apply(buf, spans)
  highlight.set(buf, spans)
end

function M.set_lines(buf, lines)
  local modifiable = vim.bo[buf].modifiable
  local readonly = vim.bo[buf].readonly
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].readonly = readonly
  vim.bo[buf].modified = false
end

function M.buffer(buf, opts)
  local readonly = opts.readonly == true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = not readonly
  vim.bo[buf].readonly = readonly
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
end

function M.keymaps(buf, maps)
  for mode, bindings in pairs(maps) do
    for lhs, rhs in pairs(bindings) do
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true })
    end
  end
end

function M.open_input(opts)
  local width = float.target_size(opts.width_ratio or 0.5, 1)
  local win, buf = float.open({
    name = opts.name,
    parent = opts.parent,
    width = width,
    height = opts.height or 1,
    fixed_height = true,
  })
  M.buffer(buf, { readonly = false, filetype = "gh-projects-input" })
  local value = sanitize(opts.value)
  M.set_lines(buf, { value })
  if opts.prompt then
    vim.api.nvim_win_set_config(win, { title = opts.prompt })
  end
  vim.api.nvim_win_set_cursor(win, { 1, #value })

  local finished = false
  local function close()
    finished = true
    float.close(opts.name)
  end
  local function active()
    return not finished and vim.api.nvim_buf_is_valid(buf) and float.is_open(opts.name)
  end
  local function submit()
    if not active() then
      return
    end
    local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    if opts.on_submit then
      opts.on_submit(text, close)
    end
  end
  local function cancel()
    if not active() then
      return
    end
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  M.keymaps(buf, {
    n = { ["<CR>"] = submit, ["<C-c>"] = cancel, q = cancel },
    i = {
      ["<CR>"] = function()
        vim.schedule(submit)
      end,
      ["<C-c>"] = function()
        vim.schedule(cancel)
      end,
    },
  })
  vim.cmd("startinsert!")
  return { win = win, buf = buf, close = close }
end

function M.open_confirm(opts)
  local width = float.target_size(opts.width_ratio or 0.4, 1)
  local win, buf = float.open({
    name = opts.name,
    parent = opts.parent,
    width = width,
    height = opts.height or 3,
    fixed_height = true,
  })
  M.buffer(buf, { readonly = true })
  M.set_lines(buf, opts.lines or {})
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local finished = false
  local function close()
    finished = true
    float.close(opts.name)
  end
  local function active()
    return not finished and vim.api.nvim_buf_is_valid(buf) and float.is_open(opts.name)
  end
  local function confirm()
    if not active() then
      return
    end
    if opts.on_confirm then
      opts.on_confirm(close)
    end
  end
  local function cancel()
    if not active() then
      return
    end
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  M.keymaps(buf, { n = { y = confirm, n = cancel, q = cancel, ["<Esc>"] = cancel } })
  return { win = win, buf = buf, close = close }
end

local function render_preview(win, buf, opts)
  local header, spans = M.header({ text = opts.header, loading = opts.loading, error = opts.error })
  local lines = { header }
  if opts.body and opts.body ~= "" then
    for _, line in ipairs(vim.split((opts.body:gsub("\r\n", "\n")), "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
  end
  M.set_lines(buf, lines)
  M.apply(buf, spans)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

function M.open_preview(opts)
  local tab = vim.api.nvim_get_current_tabpage()
  local width, height = float.target_size(opts.width_ratio or 0.7, opts.height_ratio or 0.7)
  local win, buf = float.open({
    name = opts.name,
    parent = opts.parent,
    width = width,
    height = height,
  })
  M.buffer(buf, { readonly = true, filetype = "gh-projects-preview" })
  -- The screen filetype is gh-projects-preview while the body is rendered as markdown;
  -- the custom filetype has no syntax of its own, so select markdown explicitly.
  vim.bo[buf].syntax = "markdown"
  render_preview(win, buf, opts)

  local function close()
    float.close(opts.name)
  end
  local maps = scroll_maps(win, buf)
  maps.q = close
  maps["<Esc>"] = close
  M.keymaps(buf, { n = maps })
  return { win = win, buf = buf, tab = tab, close = close }
end

function M.update_preview(screen, opts)
  if type(screen) ~= "table" or not screen.win or not screen.buf or not screen.tab then
    return false
  end
  if not vim.api.nvim_win_is_valid(screen.win) or not vim.api.nvim_buf_is_valid(screen.buf) then
    return false
  end
  if vim.api.nvim_win_get_buf(screen.win) ~= screen.buf then
    return false
  end
  if vim.api.nvim_win_get_tabpage(screen.win) ~= screen.tab then
    return false
  end
  render_preview(screen.win, screen.buf, opts)
  return true
end

function M.open_help(opts)
  local width, height = float.target_size(opts.width_ratio or 0.7, opts.height_ratio or 0.6)
  local win, buf = float.open({
    name = opts.name,
    parent = opts.parent,
    width = width,
    height = height,
  })
  M.buffer(buf, { readonly = true, filetype = "gh-projects-help" })

  local rows = opts.rows or {}
  local key_width = 0
  for _, row in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(sanitize(row[1])))
  end
  local lines = {}
  for _, row in ipairs(rows) do
    local lhs = sanitize(row[1])
    lines[#lines + 1] = lhs .. string.rep(" ", key_width - vim.fn.strdisplaywidth(lhs) + 2) .. sanitize(row[2])
  end
  M.set_lines(buf, lines)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local function close()
    float.close(opts.name)
  end
  local maps = scroll_maps(win, buf)
  maps.q = close
  maps["<Esc>"] = close
  M.keymaps(buf, { n = maps })
  return { win = win, buf = buf, close = close }
end

function M.open_select(opts)
  local width_ratio = opts.width_ratio or 0.4
  local width, height, fixed_height
  if opts.height then
    width = float.target_size(width_ratio, 1)
    height = opts.height
    fixed_height = true
  else
    width, height = float.target_size(width_ratio, opts.height_ratio or 0.6)
  end
  local win, buf = float.open({
    name = opts.name,
    parent = opts.parent,
    width = width,
    height = height,
    fixed_height = fixed_height,
  })
  M.buffer(buf, { readonly = true })

  local rows = opts.rows or {}
  local count = #rows
  local selected = count > 0 and math.max(1, math.min(count, opts.selected or 1)) or 1
  M.set_lines(buf, rows)

  local function render()
    local spans = {}
    if count > 0 and #rows[selected] > 0 then
      spans[1] = { selected - 1, 0, #rows[selected], "GitHubProjectsCardSelected" }
    end
    M.apply(buf, spans)
    vim.api.nvim_win_set_cursor(win, { selected, 0 })
  end
  render()

  local finished = false
  local function close()
    finished = true
    float.close(opts.name)
  end
  local function active()
    return not finished and vim.api.nvim_buf_is_valid(buf) and float.is_open(opts.name)
  end
  local function move(delta)
    if count == 0 then
      return
    end
    selected = math.max(1, math.min(count, selected + delta))
    render()
  end
  local function choose()
    if not active() or count == 0 then
      return
    end
    if opts.on_select then
      opts.on_select(selected, close)
    end
  end
  local function cancel()
    if not active() then
      return
    end
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  M.keymaps(buf, {
    n = {
      j = function()
        move(vim.v.count1)
      end,
      k = function()
        move(-vim.v.count1)
      end,
      ["<CR>"] = choose,
      q = cancel,
      ["<Esc>"] = cancel,
    },
  })
  return { win = win, buf = buf, close = close }
end

return M
