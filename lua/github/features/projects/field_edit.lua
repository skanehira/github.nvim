local M = {}

local float = require("github.core.float")
local ui = require("github.features.projects.ui")
local board = require("github.features.projects.board")

local CLEAR_ROW = "値を解除"
local CURRENT_MARK = "✓"
local editable_types = { TEXT = true, NUMBER = true, DATE = true, SINGLE_SELECT = true }
local type_labels = { TEXT = "Text", NUMBER = "Number", DATE = "Date" }

local states = {}
local screens = {}

local function reason(err)
  if type(err) == "table" and type(err.reason) == "string" then
    return err.reason
  end
  return tostring(err)
end

local function notify_error(message)
  vim.notify("GitHub projects: " .. message, vim.log.levels.ERROR)
end

local function sanitize(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%c", " "))
end

local function win_for(buf)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
    end
  end
end

local function valid_screen(screen)
  if not screen or not vim.api.nvim_win_is_valid(screen.win) then
    return false
  end
  if not vim.api.nvim_buf_is_valid(screen.buf) then
    return false
  end
  if vim.api.nvim_win_get_buf(screen.win) ~= screen.buf then
    return false
  end
  return vim.api.nvim_win_get_tabpage(screen.win) == screen.tab
end

local function close_screen(screen)
  if not valid_screen(screen) then
    return
  end
  if vim.api.nvim_get_current_tabpage() == screen.tab then
    float.close(screen.name)
  else
    pcall(vim.api.nvim_win_close, screen.win, true)
  end
end

local function find_item(state, item_id)
  for _, item in ipairs(state.items or {}) do
    if item.id == item_id then
      return item
    end
  end
end

local function editable_fields(fields)
  local result = {}
  for _, field in ipairs(fields or {}) do
    if editable_types[field.dataType] then
      result[#result + 1] = field
    end
  end
  return result
end

local function header_text(item)
  local content = item.content
  if type(content) == "table" then
    local number = tonumber(content.number)
    if number then
      return "Fields for #" .. number .. " " .. sanitize(content.title)
    end
    if type(content.title) == "string" then
      return "Fields for " .. sanitize(content.title)
    end
  end
  if item.type == "REDACTED" then
    return "Fields for [redacted]"
  end
  return "Fields for " .. tostring(item.type)
end

local function current_value(field, item)
  local value = type(item.values) == "table" and item.values[field.id] or nil
  if type(value) ~= "table" then
    return "未設定", nil
  end
  if field.dataType == "SINGLE_SELECT" then
    local option_id = value.option_id or value.value
    if type(option_id) ~= "string" then
      return "未設定", nil
    end
    for _, option in ipairs(field.options or {}) do
      if option.id == option_id then
        return sanitize(option.name), ui.color_group(option.color)
      end
    end
    return "不明 (" .. sanitize(option_id) .. ")", nil
  end
  if field.dataType == "TEXT" then
    if value.kind == "text" and type(value.value) == "string" and value.value ~= "" then
      return sanitize(value.value), nil
    end
  elseif field.dataType == "NUMBER" then
    if value.kind == "number" and type(value.value) == "number" then
      return tostring(value.value), nil
    end
  elseif field.dataType == "DATE" then
    if value.kind == "date" and type(value.value) == "string" then
      return sanitize(value.value), nil
    end
  end
  return "未設定", nil
end

local function raw_value(field, item)
  local value = type(item.values) == "table" and item.values[field.id] or nil
  if type(value) ~= "table" then
    return ""
  end
  if field.dataType == "TEXT" and value.kind == "text" and type(value.value) == "string" then
    return value.value
  end
  if field.dataType == "NUMBER" and value.kind == "number" and type(value.value) == "number" then
    return tostring(value.value)
  end
  if field.dataType == "DATE" and value.kind == "date" and type(value.value) == "string" then
    return value.value
  end
  return ""
end

local function finite_number(text)
  local number = tonumber(text)
  if number == nil or number ~= number then
    return false
  end
  return number ~= math.huge and number ~= -math.huge
end

local function leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and leap_year(year) then
    return 29
  end
  return days[month]
end

local function valid_date(text)
  local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if year < 1 or year > 9999 then
    return false
  end
  if month < 1 or month > 12 then
    return false
  end
  return day >= 1 and day <= days_in_month(year, month)
end

local render_editor

local function open_options(editor_buf, state, field)
  local screen = screens[editor_buf]
  if not screen then
    return
  end
  local board_state = board.state(state.board)
  local item = board_state and find_item(board_state, state.item_id)
  if not item then
    state.error = "item not found"
    render_editor(editor_buf)
    return
  end
  local options = type(field.options) == "table" and field.options or {}
  local value = type(item.values) == "table" and item.values[field.id] or nil
  local current_id = type(value) == "table" and (value.option_id or value.value) or nil
  local rows = {}
  local selected = 1
  for index, option in ipairs(options) do
    local row = "● " .. sanitize(option.name)
    if option.id == current_id then
      row = row .. "  " .. CURRENT_MARK
      selected = index
    end
    rows[#rows + 1] = row
  end
  rows[#rows + 1] = CLEAR_ROW
  local generation = state.generation
  local name = "projects-field-options:" .. field.id
  local width, height = float.target_size(0.4, 0.6)
  local win, options_buf = float.open({ name = name, parent = screen.win, width = width, height = height })
  ui.buffer(options_buf, { readonly = false })
  local meta = { name = name, win = win, buf = options_buf, tab = vim.api.nvim_get_current_tabpage() }
  local error_text = nil
  local finished = false

  local function render_options()
    local header, spans = ui.header({ text = sanitize(field.name), error = error_text })
    local lines = { header }
    for _, row in ipairs(rows) do
      lines[#lines + 1] = row
    end
    local all_spans = {}
    for _, span in ipairs(spans) do
      all_spans[#all_spans + 1] = span
    end
    for index, option in ipairs(options) do
      if index == selected then
        all_spans[#all_spans + 1] = { index, 0, #rows[index], "GitHubProjectsCardSelected" }
      else
        local group = ui.color_group(option.color)
        if group then
          all_spans[#all_spans + 1] = { index, 0, #rows[index], group }
        end
      end
    end
    if selected == #rows then
      all_spans[#all_spans + 1] = { #rows, 0, #rows[#rows], "GitHubProjectsCardSelected" }
    end
    ui.set_lines(options_buf, lines)
    ui.apply(options_buf, all_spans)
    vim.api.nvim_win_set_cursor(win, { selected + 1, 0 })
  end

  local function close_options()
    if finished then
      return
    end
    finished = true
    close_screen(meta)
  end

  local function move(delta)
    if finished or not valid_screen(meta) then
      return
    end
    selected = math.max(1, math.min(#rows, selected + delta))
    render_options()
  end

  local function apply()
    if finished or not valid_screen(meta) or state.loading then
      return
    end
    local board_now = board.state(state.board)
    if not board_now or state.generation ~= generation then
      return
    end
    local item_now = find_item(board_now, state.item_id)
    if not item_now then
      error_text = "item not found"
      render_options()
      return
    end
    local value_now = type(item_now.values) == "table" and item_now.values[field.id] or nil
    local current_id_now = type(value_now) == "table" and (value_now.option_id or value_now.value) or nil
    local option = selected <= #options and options[selected] or nil
    if option then
      if option.id == current_id_now then
        close_options()
        return
      end
    elseif current_id_now == nil then
      close_options()
      return
    end
    local api = require("github.features.projects.api").new()
    state.loading = "Updating..."
    state.error = nil
    render_editor(editor_buf)
    local submitted_generation = state.generation
    local function done(result, err)
      if state.generation ~= submitted_generation then
        return
      end
      local board_later = board.state(state.board)
      if not board_later then
        return
      end
      if not result then
        state.loading = nil
        state.error = reason(err)
        render_editor(editor_buf)
        if valid_screen(meta) and not finished then
          error_text = state.error
          render_options()
        end
        return
      end
      state.loading = nil
      state.error = nil
      if option then
        board.update_field(state.board, state.item_id, field.id, result.value)
      else
        board.update_field(state.board, state.item_id, field.id, nil)
      end
      render_editor(editor_buf)
      close_options()
    end
    if option then
      api.update_field(board_now.project.id, state.item_id, field, option.id, done)
    else
      api.clear_field(board_now.project.id, state.item_id, field.id, done)
    end
  end

  ui.keymaps(options_buf, {
    n = {
      j = function()
        move(vim.v.count1)
      end,
      k = function()
        move(-vim.v.count1)
      end,
      ["<CR>"] = apply,
      q = close_options,
      ["<Esc>"] = close_options,
      ["<C-c>"] = close_options,
    },
  })
  render_options()
end

local function show_input_error(meta, prompt, message)
  if not valid_screen(meta) then
    return
  end
  vim.api.nvim_win_set_config(meta.win, {
    title = { { prompt, "FloatTitle" }, { "  Error: " .. message, "GitHubProjectsError" } },
  })
end

local function open_input(editor_buf, state, field)
  local screen = screens[editor_buf]
  if not screen then
    return
  end
  local board_state = board.state(state.board)
  local item = board_state and find_item(board_state, state.item_id)
  if not item then
    state.error = "item not found"
    render_editor(editor_buf)
    return
  end
  local prompt = sanitize(field.name) .. " (" .. type_labels[field.dataType] .. ")"
  local value = raw_value(field, item)
  local generation = state.generation
  local name = "projects-field-input:" .. field.id
  local meta

  local function submit(text)
    if not valid_screen(meta) or state.loading then
      return
    end
    local board_now = board.state(state.board)
    if not board_now or state.generation ~= generation then
      return
    end
    local item_now = find_item(board_now, state.item_id)
    if not item_now then
      show_input_error(meta, prompt, "item not found")
      return
    end
    local validation
    if text ~= "" and field.dataType == "NUMBER" and not finite_number(text) then
      validation = "number value must be finite"
    elseif text ~= "" and field.dataType == "DATE" and not valid_date(text) then
      validation = "date value must be YYYY-MM-DD and exist"
    end
    if validation then
      state.error = validation
      render_editor(editor_buf)
      show_input_error(meta, prompt, validation)
      return
    end
    local api = require("github.features.projects.api").new()
    state.loading = "Updating..."
    state.error = nil
    render_editor(editor_buf)
    local submitted_generation = state.generation
    local function done(result, err)
      if state.generation ~= submitted_generation then
        return
      end
      local board_later = board.state(state.board)
      if not board_later then
        return
      end
      if not result then
        state.loading = nil
        state.error = reason(err)
        render_editor(editor_buf)
        if valid_screen(meta) then
          show_input_error(meta, prompt, state.error)
        end
        return
      end
      state.loading = nil
      state.error = nil
      if text == "" then
        board.update_field(state.board, state.item_id, field.id, nil)
      else
        board.update_field(state.board, state.item_id, field.id, result.value)
      end
      render_editor(editor_buf)
      close_screen(meta)
    end
    if text == "" then
      api.clear_field(board_now.project.id, state.item_id, field.id, done)
    else
      api.update_field(board_now.project.id, state.item_id, field, text, done)
    end
  end

  local handle = ui.open_input({
    name = name,
    parent = screen.win,
    prompt = prompt,
    value = value,
    on_submit = submit,
  })
  meta = { name = name, win = handle.win, buf = handle.buf, tab = vim.api.nvim_get_current_tabpage() }
  vim.keymap.set("n", "<Esc>", function()
    if valid_screen(meta) then
      close_screen(meta)
    end
  end, { buffer = handle.buf, silent = true, nowait = true })
end

render_editor = function(editor_buf)
  local state = states[editor_buf]
  local screen = screens[editor_buf]
  if not state or not screen or not valid_screen(screen) then
    return
  end
  local board_state = board.state(state.board)
  if not board_state then
    return
  end
  local item = find_item(board_state, state.item_id)
  local header, spans
  if item then
    header, spans = ui.header({ text = header_text(item), loading = state.loading, error = state.error })
  else
    header, spans = ui.header({
      text = "Fields for item",
      loading = state.loading,
      error = state.error or "item not found",
    })
  end
  local lines = { header }
  local all_spans = {}
  for _, span in ipairs(spans) do
    all_spans[#all_spans + 1] = span
  end
  local cursor = 1
  if item then
    if #state.fields == 0 then
      lines[#lines + 1] = "No editable fields"
      cursor = 2
    else
      for index, field in ipairs(state.fields) do
        local value, group = current_value(field, item)
        local name = sanitize(field.name)
        local line = name .. "  " .. value
        lines[#lines + 1] = line
        local row = #lines - 1
        if index == state.selected then
          all_spans[#all_spans + 1] = { row, 0, #line, "GitHubProjectsCardSelected" }
        elseif group then
          all_spans[#all_spans + 1] = { row, #name + 2, #line, group }
        end
      end
      cursor = state.selected + 1
    end
  end
  ui.set_lines(editor_buf, lines)
  ui.apply(editor_buf, all_spans)
  vim.api.nvim_win_set_cursor(screen.win, { cursor, 0 })
end

local function close_editor(editor_buf)
  local screen = screens[editor_buf]
  if screen then
    close_screen(screen)
  end
end

local function move_field(editor_buf, delta)
  local state = states[editor_buf]
  if not state or #state.fields == 0 then
    return
  end
  state.selected = math.max(1, math.min(#state.fields, state.selected + delta))
  render_editor(editor_buf)
end

local function open_field(editor_buf)
  local state = states[editor_buf]
  if not state or state.loading then
    return
  end
  local field = state.fields[state.selected]
  if not field then
    return
  end
  local board_state = board.state(state.board)
  local item = board_state and find_item(board_state, state.item_id)
  if not item then
    state.error = "item not found"
    render_editor(editor_buf)
    return
  end
  state.error = nil
  render_editor(editor_buf)
  if field.dataType == "SINGLE_SELECT" then
    open_options(editor_buf, state, field)
  else
    open_input(editor_buf, state, field)
  end
end

local function setup_editor_screen(editor_buf)
  ui.keymaps(editor_buf, {
    n = {
      j = function()
        move_field(editor_buf, vim.v.count1)
      end,
      k = function()
        move_field(editor_buf, -vim.v.count1)
      end,
      ["<CR>"] = function()
        open_field(editor_buf)
      end,
      q = function()
        close_editor(editor_buf)
      end,
      ["<Esc>"] = function()
        close_editor(editor_buf)
      end,
    },
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = editor_buf,
    once = true,
    callback = function()
      states[editor_buf] = nil
      screens[editor_buf] = nil
    end,
  })
end

function M.open(buf)
  local board_state = board.state(buf)
  if not board_state then
    return
  end
  local item = board.selected_item(buf)
  if not item then
    notify_error("select an item first")
    return
  end
  local parent = win_for(buf)
  if not parent then
    return
  end
  if vim.api.nvim_win_get_tabpage(parent) ~= vim.api.nvim_get_current_tabpage() then
    return
  end
  local fields = editable_fields(board_state.fields)
  local name = "projects-fields:" .. tostring(board_state.project.id)
  local existing_win, existing_buf = float.focus(name)
  if existing_win and states[existing_buf] then
    local state = states[existing_buf]
    state.item_id = item.id
    state.fields = fields
    state.selected = 1
    state.error = nil
    state.loading = nil
    state.generation = state.generation + 1
    render_editor(existing_buf)
    return
  end
  local width, height = float.target_size(0.5, 0.6)
  local win, editor_buf = float.open({ name = name, parent = parent, width = width, height = height })
  ui.buffer(editor_buf, { readonly = true, filetype = "gh-projects-editor" })
  states[editor_buf] = {
    board = buf,
    item_id = item.id,
    fields = fields,
    selected = 1,
    loading = nil,
    error = nil,
    generation = 1,
  }
  screens[editor_buf] = { name = name, win = win, buf = editor_buf, tab = vim.api.nvim_get_current_tabpage() }
  setup_editor_screen(editor_buf)
  render_editor(editor_buf)
end

return M
