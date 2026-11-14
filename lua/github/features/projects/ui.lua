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

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad_to(text, width)
  local padding = width - display_width(text)
  if padding > 0 then
    return text .. string.rep(" ", padding)
  end
  return text
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
    return "GitHubProjectsLabel"
  end
  local name = "GitHubProjectsLabel_" .. hex
  if vim.fn.hlexists(name) == 0 then
    local fg = luminance(hex) > 0.55 and "#0d1117" or "#ffffff"
    vim.api.nvim_set_hl(0, name, { bg = "#" .. hex, fg = fg, default = true })
  end
  return name
end

local AVATAR_COLORS = { "#1f6feb", "#8957e5", "#3fb950", "#d29922", "#db61a2", "#f85149" }

local function avatar_group(login)
  local hash = 0
  for index = 1, #login do
    hash = (hash * 31 + login:byte(index)) % 1000003
  end
  local color = AVATAR_COLORS[(hash % #AVATAR_COLORS) + 1]
  local name = "GitHubProjectsAvatar_" .. login:gsub("[^%w_]", "_")
  if vim.fn.hlexists(name) == 0 then
    vim.api.nvim_set_hl(0, name, { bg = color, fg = "#ffffff", bold = true, default = true })
  end
  return name
end

local function avatar_glyph(login)
  local first = login:sub(1, 1):upper()
  if first:match("^[A-Z]$") then
    return vim.fn.nr2char(0x24B6 + first:byte() - 65)
  end
  return "●"
end

local function item_state_group(item_type, state)
  if item_type == "PULL_REQUEST" then
    if state == "MERGED" then
      return "GitHubProjectsColorPurple"
    end
    if state == "CLOSED" then
      return "GitHubProjectsColorRed"
    end
    return "GitHubProjectsColorGreen"
  end
  if state == "CLOSED" then
    return "GitHubProjectsColorPurple"
  end
  return "GitHubProjectsColorGreen"
end

function M.wrap(text, width, max_lines)
  text = sanitize(text)
  if width <= 0 or max_lines <= 0 or text == "" then
    return {}
  end
  local chars = vim.fn.split(text, "\\zs")
  local lines = {}
  local current = ""
  local index = 1
  while index <= #chars do
    local char = chars[index]
    if display_width(current .. char) > width and current ~= "" then
      lines[#lines + 1] = current
      current = char
      if #lines == max_lines then
        break
      end
    else
      current = current .. char
    end
    index = index + 1
  end
  if #lines < max_lines then
    if current ~= "" then
      lines[#lines + 1] = current
    end
    return lines
  end
  if index <= #chars or current ~= "" then
    lines[#lines] = M.truncate(lines[#lines], width - #ELLIPSIS) .. ELLIPSIS
  end
  return lines
end

local function chip_segments(content, inner)
  local labels = content.labels
  if type(labels) ~= "table" or type(labels.nodes) ~= "table" or #labels.nodes == 0 then
    return nil
  end
  local total = tonumber(labels.totalCount) or #labels.nodes
  local segments, text, used = {}, "", 0
  for index, label in ipairs(labels.nodes) do
    if index > 2 then
      break
    end
    local name = sanitize(label.name)
    if name ~= "" then
      local chip = " " .. name .. " "
      if used + display_width(chip) > inner then
        local available = inner - used - 2
        if available < 1 then
          break
        end
        chip = " " .. M.truncate(name, available) .. " "
      end
      local width = display_width(chip)
      if used + width > inner then
        break
      end
      segments[#segments + 1] = { #text, label_group(label.color), #chip }
      text = text .. chip
      used = used + width
    end
  end
  if #segments == 0 then
    return nil
  end
  if total > #segments then
    local more = "+" .. (total - #segments)
    local chip = " " .. more .. " "
    if used + display_width(chip) <= inner then
      segments[#segments + 1] = { #text, "GitHubProjectsLabelMore", #chip }
      text = text .. chip
    end
  end
  return text, segments
end

local function avatar_segments(content, inner)
  local assignees = content.assignees
  if type(assignees) ~= "table" or type(assignees.nodes) ~= "table" or #assignees.nodes == 0 then
    return nil
  end
  local total = tonumber(assignees.totalCount) or #assignees.nodes
  local glyphs = {}
  for index, assignee in ipairs(assignees.nodes) do
    if index > 3 then
      break
    end
    local login = sanitize(assignee.login)
    if login ~= "" then
      glyphs[#glyphs + 1] = { glyph = avatar_glyph(login), group = avatar_group(login) }
    end
  end
  if #glyphs == 0 then
    return nil
  end
  if total > #glyphs then
    glyphs[#glyphs + 1] = { glyph = "+" .. (total - #glyphs), group = "GitHubProjectsMeta" }
  end
  local text = ""
  for index, glyph in ipairs(glyphs) do
    if index > 1 then
      text = text .. " "
    end
    text = text .. glyph.glyph
  end
  if display_width(text) > inner then
    text = M.truncate(text, inner)
  end
  local pad = math.max(0, inner - display_width(text))
  local segments = {}
  local offset = pad
  for index, glyph in ipairs(glyphs) do
    if index > 1 then
      offset = offset + 1
    end
    segments[#segments + 1] = { offset, glyph.group, #glyph.glyph }
    offset = offset + #glyph.glyph
  end
  return string.rep(" ", pad) .. text, segments
end

local function progress_segments(content, inner)
  local summary = content.subIssuesSummary
  if type(summary) ~= "table" then
    return nil
  end
  local total = tonumber(summary.total) or 0
  if total <= 0 then
    return nil
  end
  local completed = math.max(0, math.min(total, tonumber(summary.completed) or 0))
  local prefix = string.format("%d/%d ", completed, total)
  local suffix = string.format(" %d%%", math.floor(completed * 100 / total))
  local bar_width = inner - display_width(prefix) - display_width(suffix)
  if bar_width < 1 then
    return nil
  end
  local filled = math.floor(bar_width * completed / total)
  local filled_text = string.rep("█", filled)
  local empty_text = string.rep("░", bar_width - filled)
  local text = prefix .. filled_text .. empty_text .. suffix
  local segments = {
    { 0, "GitHubProjectsMeta", #prefix },
    { #prefix, "GitHubProjectsProgress", #filled_text },
    { #prefix + #filled_text, "GitHubProjectsProgressEmpty", #empty_text },
    { #prefix + #filled_text + #empty_text, "GitHubProjectsMeta", #suffix },
  }
  local filtered = {}
  for _, segment in ipairs(segments) do
    if segment[3] > 0 then
      filtered[#filtered + 1] = segment
    end
  end
  return text, filtered
end

local function related_segments(content, inner)
  local references = content.closedByPullRequestsReferences
  if type(references) ~= "table" or type(references.nodes) ~= "table" then
    return nil
  end
  local parts = {}
  for index, reference in ipairs(references.nodes) do
    if index > 2 then
      break
    end
    local number = tonumber(reference.number)
    if number then
      parts[#parts + 1] = "⇄ #" .. number
    end
  end
  if #parts == 0 then
    return nil
  end
  local total = tonumber(references.totalCount) or #parts
  if total > #parts then
    parts[#parts + 1] = "+" .. (total - #parts)
  end
  local text = M.truncate(table.concat(parts, " "), inner)
  return text, { { 0, "GitHubProjectsMeta", #text } }
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

function M.board_column_width(inner_width, configured, visible)
  configured = math.max(20, math.min(80, configured or 36))
  visible = math.max(1, visible or 1)
  local available = inner_width - (visible - 1)
  local width = math.floor(available / visible)
  return math.max(1, math.min(inner_width, math.max(configured, width)))
end

function M.board_column_widths(inner_width, configured, visible)
  configured = math.max(20, math.min(80, configured or 36))
  visible = math.max(1, visible or 1)
  local available = math.max(0, inner_width - (visible - 1))
  local base = math.floor(available / visible)
  local width = math.max(1, math.min(inner_width, math.max(configured, base)))
  local widths = {}
  for index = 1, visible do
    widths[index] = width
  end
  local remainder = available - width * visible
  if remainder > 0 then
    widths[visible] = widths[visible] + remainder
  end
  return widths
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

  if width < 10 then
    local text = "[redacted]"
    if body and item_type == "DRAFT_ISSUE" then
      text = "✎ " .. sanitize(body.title)
    elseif body and tonumber(body.number) and (item_type == "ISSUE" or item_type == "PULL_REQUEST") then
      text = (item_type == "ISSUE" and "○ #" or "⇄ #") .. tonumber(body.number) .. " " .. sanitize(body.title)
    end
    local line = M.pad(text, width)
    return { line }, selected and { { 0, 0, #line, "GitHubProjectsCardSelected" } } or {}
  end

  local inner = width - 4
  local bg = selected and "GitHubProjectsCardSelected" or "GitHubProjectsCard"
  local border = selected and "GitHubProjectsCardSelectedBorder" or "GitHubProjectsCardBorder"
  local lines, spans = {}, {}

  local function add_border(text)
    lines[#lines + 1] = text
    local row = #lines - 1
    spans[#spans + 1] = { row, 0, #text, bg }
    spans[#spans + 1] = { row, 0, #text, border }
  end

  local function add_line(text, segments)
    local line = "│ " .. pad_to(text, inner) .. " │"
    lines[#lines + 1] = line
    local row = #lines - 1
    spans[#spans + 1] = { row, 0, #line, bg }
    spans[#spans + 1] = { row, 0, 3, border }
    spans[#spans + 1] = { row, #line - 3, #line, border }
    for _, segment in ipairs(segments or {}) do
      local start = 4 + segment[1]
      local stop = start + segment[3]
      if stop > start then
        spans[#spans + 1] = { row, start, stop, segment[2] }
      end
    end
  end

  add_border("╭" .. string.rep("─", width - 2) .. "╮")

  local content_lines = {}
  if body and item_type == "DRAFT_ISSUE" then
    local icon = "✎"
    local prefix = icon .. " "
    local title = sanitize(body.title)
    local title_width = math.max(1, inner - display_width(prefix))
    local wrapped = M.wrap(title, title_width, 1000)
    local prefix_segments = {
      { 0, "GitHubProjectsColorGray", #icon },
      { #icon, "GitHubProjectsNumber", #" " },
    }
    if #wrapped == 0 then
      content_lines[#content_lines + 1] = { prefix, prefix_segments }
    else
      content_lines[#content_lines + 1] = {
        prefix .. wrapped[1],
        { prefix_segments[1], prefix_segments[2], { #prefix, "GitHubProjectsCardTitle", #wrapped[1] } },
      }
      local indent = display_width(prefix)
      for index = 2, #wrapped do
        content_lines[#content_lines + 1] = {
          string.rep(" ", indent) .. wrapped[index],
          { { indent, "GitHubProjectsCardTitle", #wrapped[index] } },
        }
      end
    end
  elseif body and tonumber(body.number) and (item_type == "ISSUE" or item_type == "PULL_REQUEST") then
    local number = tonumber(body.number)
    local icon = item_type == "ISSUE" and "◉" or "⇄"
    local icon_group = item_state_group(item_type, body.state)
    local number_text = " #" .. number .. " "
    local prefix = icon .. number_text
    local title = sanitize(body.title)
    local title_width = math.max(1, inner - display_width(prefix))
    local wrapped = M.wrap(title, title_width, 1000)
    local prefix_segments = {
      { 0, icon_group, #icon },
      { #icon, "GitHubProjectsNumber", #number_text },
    }
    if #wrapped == 0 then
      content_lines[#content_lines + 1] = { prefix, prefix_segments }
    else
      content_lines[#content_lines + 1] = {
        prefix .. wrapped[1],
        { prefix_segments[1], prefix_segments[2], { #prefix, "GitHubProjectsCardTitle", #wrapped[1] } },
      }
      local indent = display_width(prefix)
      for index = 2, #wrapped do
        content_lines[#content_lines + 1] = {
          string.rep(" ", indent) .. wrapped[index],
          { { indent, "GitHubProjectsCardTitle", #wrapped[index] } },
        }
      end
    end

    local labels_text, labels_segments = chip_segments(body, inner)
    local avatars_text, avatars_segments = avatar_segments(body, inner)
    local progress_text, progress_spans = progress_segments(body, inner)
    local related_text, related_spans = related_segments(body, inner)
    local has_meta = labels_text or avatars_text or progress_text or related_text
    if has_meta then
      content_lines[#content_lines + 1] = { "", {} }
    end
    if labels_text then
      content_lines[#content_lines + 1] = { labels_text, labels_segments }
    end
    if avatars_text then
      content_lines[#content_lines + 1] = { avatars_text, avatars_segments }
    end
    if progress_text then
      content_lines[#content_lines + 1] = { progress_text, progress_spans }
    end
    if related_text then
      content_lines[#content_lines + 1] = { related_text, related_spans }
    end
  else
    content_lines[#content_lines + 1] = { "[redacted]", { { 0, "GitHubProjectsRedacted", #"[redacted]" } } }
  end

  for _, content_line in ipairs(content_lines) do
    add_line(content_line[1], content_line[2])
  end

  add_border("╰" .. string.rep("─", width - 2) .. "╯")
  return lines, spans
end

function M.column_header(column, width, selected)
  local marker = column.no_value and "○" or "●"
  local name = column.no_value and "値なし" or sanitize(column.name)
  local count = tostring(column.count or 0)
  local plus = "+"
  local available = math.max(1, width - display_width(plus) - 1)
  local left = M.truncate(marker .. " " .. name .. " " .. count, available)
  local line = pad_to(left, available) .. " " .. plus
  line = pad_to(line, width)
  local spans = {}
  local bg = selected and "GitHubProjectsColumnSelected" or "GitHubProjectsColumnHeader"
  spans[#spans + 1] = { 0, 0, #line, bg }
  local group = M.color_group(column.color)
  if group then
    spans[#spans + 1] = { 0, 0, #marker, group }
  end
  local name_start = #marker + 1
  local name_end = math.min(name_start + #name, #left)
  if name_end > name_start then
    spans[#spans + 1] = { 0, name_start, name_end, "GitHubProjectsColumn" }
  end
  local count_start = name_end + 1
  local count_group = selected and "GitHubProjectsColumnSelected" or "GitHubProjectsMeta"
  if count_start < #left then
    spans[#spans + 1] = { 0, count_start, #left, count_group }
  end
  local plus_group = selected and "GitHubProjectsColumnSelected" or "GitHubProjectsMeta"
  spans[#spans + 1] = { 0, #line - 1, #line, plus_group }
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
