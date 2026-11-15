local M = {}

local header = require("github.features.issues.header")

local namespace = vim.api.nvim_create_namespace("github_issue_detail")
local states = {}
local attached = {}
local resized = false

local function sanitize(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%c", " "))
end

function M.title_text(title)
  return sanitize(title)
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

local function apply_spans(buf, issue)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 4, false)
  for _, span in ipairs(header.spans(lines, issue)) do
    vim.api.nvim_buf_set_extmark(buf, namespace, span[1], span[2], {
      end_col = span[3],
      hl_group = span[4],
      priority = 90,
    })
  end
end

function M.apply(buf, issue, target)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if vim.api.nvim_buf_line_count(buf) < 4 then
    return
  end
  local width = buffer_width(buf)
  local above = { {} }
  vim.list_extend(above, state_lines(issue, target, width))
  above[#above + 1] = {}
  vim.api.nvim_buf_set_extmark(buf, namespace, 1, 0, {
    virt_lines = above,
    virt_lines_above = true,
    priority = 100,
  })
  local below = {
    { { string.rep("─", width), "gh_issue_separator" } },
    {},
  }
  vim.api.nvim_buf_set_extmark(buf, namespace, 3, 0, {
    virt_lines = below,
    priority = 100,
  })
  apply_spans(buf, issue)
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
          M.apply(buf, state.issue, state.target)
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
        M.apply(buf, state.issue, state.target)
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
  local modified = vim.bo[buf].modified
  if vim.api.nvim_buf_line_count(buf) >= 4 then
    local desired = header.lines(issue)
    if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 1, 4, false), desired) then
      vim.api.nvim_buf_set_lines(buf, 1, 4, false, desired)
    end
  end
  M.apply(buf, issue, target)
  if not modified then
    vim.bo[buf].modified = false
  end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] == 1 then
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
  end
end

return M
