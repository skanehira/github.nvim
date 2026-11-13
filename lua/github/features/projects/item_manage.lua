local M = {}

local float = require("github.core.float")
local ui = require("github.features.projects.ui")
local board = require("github.features.projects.board")

local HOST = "github.com"
local flows = {}
local confirms = {}
local submit_existing
local submit_draft
local submit_delete

local function reason(err)
  if type(err) == "table" and type(err.reason) == "string" then
    return err.reason
  end
  return tostring(err)
end

local function notify_info(message)
  vim.notify("GitHub projects: " .. message, vim.log.levels.INFO)
end

local function notify_error(message)
  vim.notify("GitHub projects: " .. message, vim.log.levels.ERROR)
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function names(buf)
  return {
    select = "projects-add:select:" .. buf,
    existing = "projects-add:existing:" .. buf,
    title = "projects-add:title:" .. buf,
    body = "projects-add:body:" .. buf,
    confirm = "projects-delete:confirm:" .. buf,
  }
end

local function board_window(buf)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
    end
  end
end

local function close_screen(name, screen)
  if type(screen) ~= "table" or not screen.win or not vim.api.nvim_win_is_valid(screen.win) then
    return
  end
  if vim.api.nvim_win_get_tabpage(screen.win) == vim.api.nvim_get_current_tabpage() then
    float.close(name)
  else
    pcall(vim.api.nvim_win_close, screen.win, true)
  end
end

local function focus_flow(flow)
  local screen_names = names(flow.board)
  for _, name in ipairs({ screen_names.body, screen_names.title, screen_names.existing, screen_names.select }) do
    local win = float.focus(name)
    if win then
      return win
    end
  end
end

local function clear_flow(flow)
  if flows[flow.board] == flow then
    flows[flow.board] = nil
  end
end

local function close_flow(flow)
  local screen_names = names(flow.board)
  clear_flow(flow)
  if float.is_open(screen_names.select) then
    float.close(screen_names.select)
    return
  end
  for _, key in ipairs({ "body", "title", "existing", "select" }) do
    close_screen(screen_names[key], flow.screens[key])
  end
end

local function valid_owner(owner)
  if type(owner) ~= "string" then
    return false
  end
  if #owner == 1 then
    return owner:match("^[%w]$") ~= nil
  end
  return owner:match("^[%w][%w%-]*[%w]$") ~= nil
end

local function valid_repo(repo)
  return type(repo) == "string" and repo:match("^[%w_.%-]+$") ~= nil
end

local function positive_number(value)
  if type(value) ~= "string" or not value:match("^%d+$") then
    return false
  end
  local number = tonumber(value)
  return number ~= nil and number > 0 and number == math.floor(number) and number <= 9007199254740991
end

local INVALID_REFERENCE = "invalid Issue/PR reference; use https://github.com/<owner>/<repo>/issues/<number>, "
  .. "https://github.com/<owner>/<repo>/pull/<number> or <owner>/<repo>#<number>"

local function parse_reference(value)
  local text = trim(value)
  if text == "" then
    return nil, "enter an Issue/PR URL or owner/repo#number"
  end
  local owner, repo, number
  local url_owner, url_repo, resource, url_number = text:match("^https://github%.com/([^/]+)/([^/]+)/(%a+)/([^/]+)/?$")
  if url_owner then
    if text:find("[?#]") or (resource ~= "issues" and resource ~= "pull") then
      return nil, INVALID_REFERENCE
    end
    owner, repo, number = url_owner, url_repo, url_number
  else
    owner, repo, number = text:match("^([^/]+)/([^#]+)#(.+)$")
  end
  if not owner then
    return nil, INVALID_REFERENCE
  end
  if not valid_owner(owner) or not valid_repo(repo) then
    return nil, "invalid owner or repository"
  end
  if not positive_number(number) then
    return nil, "invalid Issue/PR number"
  end
  return { owner = owner, repo = repo, number = tonumber(number) }
end

local function item_labels(item)
  local content = item.content
  if type(content) ~= "table" or type(content.labels) ~= "table" or type(content.labels.nodes) ~= "table" then
    return {}, 0
  end
  local values = {}
  for _, label in ipairs(content.labels.nodes) do
    if type(label.name) == "string" then
      values[#values + 1] = label.name:lower()
    end
  end
  local total = content.labels.total_count
  if type(total) ~= "number" or total < #values then
    total = #values
  end
  return values, total
end

local function item_assignees(item)
  local content = item.content
  if type(content) ~= "table" or type(content.assignees) ~= "table" or type(content.assignees.nodes) ~= "table" then
    return {}, 0
  end
  local values = {}
  for _, assignee in ipairs(content.assignees.nodes) do
    if type(assignee.login) == "string" then
      values[#values + 1] = assignee.login:lower()
    end
  end
  local total = content.assignees.total_count
  if type(total) ~= "number" or total < #values then
    total = #values
  end
  return values, total
end

local function list_matches(values, total, wanted)
  local truncated = total > #values
  for _, value in ipairs(wanted) do
    if vim.tbl_contains(values, value) then
      return true
    end
  end
  if truncated then
    return nil
  end
  return false
end

local function find_field(state, name)
  local wanted = name:lower()
  for _, field in ipairs(state.fields or {}) do
    if type(field.name) == "string" and field.name:lower() == wanted then
      return field
    end
  end
  local group = state.group_field
  if type(group) == "table" and type(group.name) == "string" and group.name:lower() == wanted then
    return group
  end
end

local function field_value(state, item, name)
  local field = find_field(state, name)
  if not field then
    return nil, "unknown"
  end
  local value = type(item.values) == "table" and item.values[field.id]
  if type(value) ~= "table" then
    return nil, "unset"
  end
  local text = value.name or value.value
  if type(text) == "string" or type(text) == "number" then
    return tostring(text):lower(), "set"
  end
  return nil, "unset"
end

local function split_values(value)
  local values = {}
  for part in value:gmatch("[^,]+") do
    values[#values + 1] = part:lower()
  end
  return values
end

local function filter_terms(filter)
  if filter:find("[\"']") or filter:find("[()]") then
    return nil
  end
  local terms = {}
  for token in filter:gmatch("%S+") do
    terms[#terms + 1] = token
  end
  return terms
end

local function term_matches(state, item, token)
  local negate = token:sub(1, 1) == "-"
  if negate then
    token = token:sub(2)
  end
  local field, raw_values = token:match("^([%w_]+):(.+)$")
  if not field then
    return nil
  end
  field = field:lower()
  local values = split_values(raw_values)
  if #values == 0 then
    return nil
  end
  local result
  if field == "is" then
    result = false
    for _, value in ipairs(values) do
      local content = type(item.content) == "table" and item.content or {}
      local matched
      if value == "open" then
        matched = content.state == "OPEN"
      elseif value == "closed" then
        matched = content.state == "CLOSED"
      elseif value == "merged" then
        matched = content.state == "MERGED"
      elseif value == "pr" then
        matched = item.type == "PULL_REQUEST"
      elseif value == "issue" then
        matched = item.type == "ISSUE"
      elseif value == "draft" then
        matched = item.type == "DRAFT_ISSUE"
      else
        return nil
      end
      if matched then
        result = true
      end
    end
  elseif field == "label" then
    local labels, total = item_labels(item)
    result = list_matches(labels, total, values)
    if result == nil then
      return nil
    end
  elseif field == "assignee" or field == "assignees" then
    local assignees, total = item_assignees(item)
    result = list_matches(assignees, total, values)
    if result == nil then
      return nil
    end
  elseif field == "repo" or field == "repository" then
    local content = type(item.content) == "table" and item.content or {}
    local repository = type(content.repository) == "string" and content.repository:lower() or nil
    result = false
    for _, value in ipairs(values) do
      if repository == value then
        result = true
      end
    end
  elseif field == "no" then
    result = false
    for _, value in ipairs(values) do
      local matched
      if value == "label" then
        local _, total = item_labels(item)
        matched = total == 0
      elseif value == "assignee" or value == "assignees" then
        local _, total = item_assignees(item)
        matched = total == 0
      else
        local _, kind = field_value(state, item, value)
        if kind == "unknown" then
          return nil
        end
        matched = kind == "unset"
      end
      if matched then
        result = true
      end
    end
  else
    local text, kind = field_value(state, item, field)
    if kind == "unknown" then
      return nil
    end
    result = false
    if kind == "set" then
      for _, value in ipairs(values) do
        if text == value then
          result = true
        end
      end
    end
  end
  if negate then
    return not result
  end
  return result
end

local function filter_match(state, item)
  local filter = state.filter or ""
  if filter:match("^%s*$") then
    return true
  end
  local terms = filter_terms(filter)
  if not terms then
    return nil
  end
  local unknown = false
  for _, term in ipairs(terms) do
    local matched = term_matches(state, item, term)
    if matched == false then
      return false
    elseif matched == nil then
      unknown = true
    end
  end
  if unknown then
    return nil
  end
  return true
end

local function group_value_missing(state, item)
  local group = state.group_field
  if type(group) ~= "table" then
    return false
  end
  local value = type(item.values) == "table" and item.values[group.id]
  if type(value) ~= "table" then
    return true
  end
  local option = value.option_id or value.value
  return type(option) ~= "string" or option == ""
end

local ERROR_LABELS = {
  network = "network failure",
  forbidden = "permission denied",
  rate_limit = "rate limit exceeded",
  validation = "invalid request",
}

local function failure_message(err)
  local text = reason(err)
  local kind = type(err) == "table" and err.kind
  local label = kind and ERROR_LABELS[kind]
  if label then
    return label .. ": " .. text
  end
  return text
end

local function add_error_message(err)
  local text = failure_message(err)
  if type(err) == "table" and err.kind == "unknown" then
    return text .. "; run r to refresh"
  end
  return text
end

local function delete_error_message(err)
  local text = failure_message(err)
  if type(err) == "table" and (err.kind == "unknown" or err.kind == "not_found") then
    return text .. "; run r to refresh"
  end
  return text
end

local function finish_add(flow, item, duplicate, draft)
  local buf = flow.board
  local state = board.state(buf)
  if not state then
    return
  end
  if duplicate then
    board.select_item(buf, item.id)
    close_flow(flow)
    notify_info("the item is already in the project; selected the existing item")
    return
  end
  local match = filter_match(state, item)
  state.project.item_count = (state.project.item_count or 0) + 1
  local subject = draft and "draft issue" or "item"
  if match == false then
    close_flow(flow)
    notify_info(
      "added the "
        .. subject
        .. " to the project, but it does not match the current filter; clear the filter with ghs to see it"
    )
    return
  end
  if match == nil then
    close_flow(flow)
    notify_info(
      "added the "
        .. subject
        .. " to the project; could not determine whether it matches the current filter; "
        .. "clear the filter with ghs to see it"
    )
    return
  end
  board.add_item(buf, item)
  if draft and flow.body then
    state.body_cache[item.id] = flow.body
  end
  close_flow(flow)
  if not draft and group_value_missing(state, item) then
    notify_info("added the " .. subject .. " to the project; the group value is missing. Run r to refresh")
  elseif draft then
    notify_info("added the draft issue to the project")
  else
    notify_info("added the item to the project; it may already have been in the project. Run r to refresh")
  end
end

local function open_body(flow, parent)
  local width, height = float.target_size(0.7, 0.6)
  local win, buf = float.open({
    name = names(flow.board).body,
    parent = parent,
    width = width,
    height = height,
  })
  ui.buffer(buf, { readonly = false, filetype = "markdown" })
  vim.api.nvim_win_set_config(win, { title = "Draft body (C-s to add, q/Esc to cancel)" })
  local text = flow.body or ""
  local lines = text ~= "" and vim.split(text, "\n", { plain = true }) or { "" }
  ui.set_lines(buf, lines)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  flow.screens.body = { win = win, buf = buf }

  local function active()
    return flows[flow.board] == flow and vim.api.nvim_buf_is_valid(buf) and float.is_open(names(flow.board).body)
  end
  local function content()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function submit()
    if not active() or flow.submitting then
      return
    end
    flow.body = content()
    submit_draft(flow)
  end
  local function cancel()
    if not active() then
      return
    end
    flow.body = content()
    flow.step = "title"
    flow.generation = flow.generation + 1
    flow.submitting = false
    close_screen(names(flow.board).body, flow.screens.body)
  end

  ui.keymaps(buf, {
    n = { ["<C-s>"] = submit, q = cancel, ["<Esc>"] = cancel },
    i = {
      ["<C-s>"] = function()
        vim.schedule(submit)
      end,
    },
  })
  vim.cmd("startinsert!")
end

local function open_title(flow)
  flow.mode = "draft"
  flow.step = "title"
  local parent = flow.screens.select and flow.screens.select.win or board_window(flow.board)
  local screen
  screen = ui.open_input({
    name = names(flow.board).title,
    parent = parent,
    prompt = "Draft title",
    value = flow.title or "",
    on_submit = function(value)
      local title = trim(value)
      if title == "" then
        notify_error("draft title must not be empty")
        return
      end
      flow.title = title
      flow.step = "body"
      open_body(flow, screen.win)
    end,
    on_cancel = function()
      if flows[flow.board] ~= flow then
        return
      end
      close_flow(flow)
    end,
  })
  flow.screens.title = screen
end

local function open_existing(flow)
  flow.mode = "existing"
  flow.step = "existing"
  local parent = flow.screens.select and flow.screens.select.win or board_window(flow.board)
  local screen = ui.open_input({
    name = names(flow.board).existing,
    parent = parent,
    prompt = "Issue/PR URL or owner/repo#number",
    value = flow.input or "",
    on_submit = function(value)
      submit_existing(flow, value)
    end,
    on_cancel = function()
      if flows[flow.board] ~= flow then
        return
      end
      flow.step = "choice"
      flow.mode = nil
      flow.input = nil
      flow.generation = flow.generation + 1
      flow.submitting = false
    end,
  })
  flow.screens.existing = screen
end

function submit_existing(flow, value)
  if flows[flow.board] ~= flow or flow.submitting then
    return
  end
  local reference, reference_err = parse_reference(value)
  if not reference then
    flow.error = reference_err
    notify_error(reference_err)
    return
  end
  local state = board.state(flow.board)
  if not state then
    return
  end
  flow.input = trim(value)
  flow.submitting = true
  flow.generation = flow.generation + 1
  local generation = flow.generation
  local api = require("github.features.projects.api").new()
  api.resolve_content({ host = HOST }, flow.input, function(content, err)
    if flows[flow.board] ~= flow or flow.generation ~= generation then
      return
    end
    if not content then
      flow.submitting = false
      flow.error = reason(err)
      notify_error(add_error_message(err))
      return
    end
    local current = board.state(flow.board)
    if not current then
      return
    end
    local existing = {}
    for _, item in ipairs(current.items) do
      existing[item.id] = true
    end
    api.add_item(current.project.id, content.id, existing, function(result, add_err)
      if flows[flow.board] ~= flow or flow.generation ~= generation then
        return
      end
      flow.submitting = false
      if not result then
        flow.error = reason(add_err)
        notify_error(add_error_message(add_err))
        return
      end
      finish_add(flow, result.item, result.duplicate, false)
    end)
  end)
end

function submit_draft(flow)
  if flows[flow.board] ~= flow or flow.submitting then
    return
  end
  local state = board.state(flow.board)
  if not state then
    return
  end
  local title = trim(flow.title or "")
  if title == "" then
    notify_error("draft title must not be empty")
    flow.step = "title"
    return
  end
  flow.submitting = true
  flow.generation = flow.generation + 1
  local generation = flow.generation
  local api = require("github.features.projects.api").new()
  api.add_draft(state.project.id, title, flow.body or "", function(result, err)
    if flows[flow.board] ~= flow or flow.generation ~= generation then
      return
    end
    flow.submitting = false
    if not result then
      flow.error = reason(err)
      notify_error(add_error_message(err))
      return
    end
    finish_add(flow, result.item, false, true)
  end)
end

local function confirm_item_line(item)
  local content = type(item.content) == "table" and item.content or {}
  if item.type == "ISSUE" then
    return "Issue #" .. tostring(content.number) .. " " .. tostring(content.title or "")
  elseif item.type == "PULL_REQUEST" then
    return "Pull request #" .. tostring(content.number) .. " " .. tostring(content.title or "")
  elseif item.type == "DRAFT_ISSUE" then
    return "Draft issue " .. tostring(content.title or "")
  end
  return "[redacted]"
end

local function confirm_lines(item)
  local width = float.target_size(0.4, 1)
  return {
    "Delete this item from the project?",
    ui.truncate(confirm_item_line(item), width),
    "y: delete  n/q/Esc: cancel",
  }
end

function submit_delete(confirm, close)
  if confirms[confirm.board] ~= confirm or confirm.submitting then
    return
  end
  local state = board.state(confirm.board)
  if not state then
    return
  end
  confirm.submitting = true
  confirm.generation = confirm.generation + 1
  local generation = confirm.generation
  local api = require("github.features.projects.api").new()
  api.delete_item(state.project.id, confirm.item.id, function(result, err)
    if confirms[confirm.board] ~= confirm or confirm.generation ~= generation then
      return
    end
    local current = board.state(confirm.board)
    if not current then
      return
    end
    confirm.submitting = false
    if not result then
      notify_error(delete_error_message(err))
      return
    end
    board.remove_item(confirm.board, confirm.item.id)
    current.body_cache[confirm.item.id] = nil
    current.project.item_count = math.max(0, (current.project.item_count or 0) - 1)
    confirms[confirm.board] = nil
    close()
    close_screen(names(confirm.board).confirm, confirm.screen)
    notify_info("removed the item from the project; the Issue/PR was not deleted")
  end)
end

function M.open_add(buf)
  local state = board.state(buf)
  if not state then
    return
  end
  local flow = flows[buf]
  if flow then
    if focus_flow(flow) then
      return
    end
    close_flow(flow)
  end
  local confirm = confirms[buf]
  if confirm then
    local win = float.focus(names(buf).confirm)
    if win then
      return
    end
    close_screen(names(buf).confirm, confirm.screen)
    confirms[buf] = nil
  end
  local parent = board_window(buf) or vim.api.nvim_get_current_win()
  flow = {
    board = buf,
    mode = nil,
    step = "choice",
    input = nil,
    title = nil,
    body = nil,
    error = nil,
    generation = 0,
    submitting = false,
    screens = {},
  }
  flows[buf] = flow
  local screen = ui.open_select({
    name = names(buf).select,
    parent = parent,
    width_ratio = 0.4,
    height = 4,
    rows = { "既存のIssue/PR", "下書きIssue" },
    on_select = function(index)
      if flows[buf] ~= flow then
        return
      end
      if index == 1 then
        open_existing(flow)
      else
        open_title(flow)
      end
    end,
    on_cancel = function()
      clear_flow(flow)
    end,
  })
  flow.screens.select = screen
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = screen.buf,
    once = true,
    callback = function()
      clear_flow(flow)
    end,
  })
end

function M.open_delete(buf)
  local state = board.state(buf)
  if not state then
    return
  end
  local confirm = confirms[buf]
  if confirm then
    if float.focus(names(buf).confirm) then
      return
    end
    close_screen(names(buf).confirm, confirm.screen)
    confirms[buf] = nil
  end
  local flow = flows[buf]
  if flow then
    if focus_flow(flow) then
      return
    end
    close_flow(flow)
  end
  local item = board.selected_item(buf)
  if not item then
    notify_error("select an item to delete")
    return
  end
  local parent = board_window(buf) or vim.api.nvim_get_current_win()
  confirm = {
    board = buf,
    item = item,
    generation = 0,
    submitting = false,
    screen = nil,
  }
  confirms[buf] = confirm
  local screen = ui.open_confirm({
    name = names(buf).confirm,
    parent = parent,
    width_ratio = 0.4,
    height = 3,
    lines = confirm_lines(item),
    on_confirm = function(close)
      submit_delete(confirm, close)
    end,
    on_cancel = function()
      if confirms[buf] == confirm then
        confirms[buf] = nil
      end
    end,
  })
  confirm.screen = screen
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = screen.buf,
    once = true,
    callback = function()
      if confirms[buf] == confirm then
        confirms[buf] = nil
      end
    end,
  })
end

return M
