local process = require("github.core.process")
local config = require("github.core.config")
local float = require("github.core.float")
local board = require("github.features.projects.board")

local old_run, old_notify
local calls, pending, notices

local function fake_gh()
  calls, pending, notices = {}, {}, {}
  old_run, old_notify = process.run, vim.notify
  vim.notify = function(message, level)
    notices[#notices + 1] = { message, level }
  end
  process.run = function(argv, opts, callback)
    calls[#calls + 1] = { argv = argv, opts = opts }
    pending[#pending + 1] = callback
  end
end

local function restore_gh()
  process.run, vim.notify = old_run, old_notify
end

local function respond(index, payload)
  pending[index]({ code = 0, stdout = vim.json.encode(payload) })
end

local function fail(index, code, stderr)
  pending[index]({ code = code, stdout = "", stderr = stderr })
end

local function graphql_error(index, message)
  respond(index, { errors = { { message = message } } })
end

local function variables(index)
  return vim.json.decode(calls[index].opts.stdin).variables
end

local function key(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
end

local function float_windows()
  local windows = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        windows[#windows + 1] = win
      end
    end
  end
  return windows
end

local function close_all()
  for _, win in ipairs(float_windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.cmd("silent! only!")
  vim.cmd("silent! tabonly")
end

local function current_window(filetype)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo[buf].filetype == filetype then
      return win, buf
    end
  end
end

local function options_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo[buf].filetype == "" then
      return win, buf
    end
  end
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function highlights(buf, group)
  local values = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
  do
    if not group or mark[4].hl_group == group then
      values[#values + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
    end
  end
  return values
end

local function mapping(buf, mode, lhs)
  for _, value in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if value.lhs == lhs then
      return value
    end
  end
end

local function assert_mapping(buf, mode, lhs)
  local value = mapping(buf, mode, lhs)
  assert.is_not_nil(value)
  assert.equals(1, value.silent)
  assert.equals(1, value.nowait)
end

local function status_field(options)
  return {
    __typename = "ProjectV2SingleSelectField",
    id = "status",
    name = "Status",
    dataType = "SINGLE_SELECT",
    options = options or {
      { id = "todo", name = "Todo", color = "GRAY" },
      { id = "doing", name = "In Progress", color = "BLUE" },
      { id = "done", name = "Done", color = "GREEN" },
    },
  }
end

local function notes_field()
  return {
    __typename = "ProjectV2FieldCommon",
    id = "notes",
    name = "Notes",
    dataType = "TEXT",
  }
end

local function estimate_field()
  return {
    __typename = "ProjectV2FieldCommon",
    id = "estimate",
    name = "Estimate",
    dataType = "NUMBER",
  }
end

local function due_field()
  return {
    __typename = "ProjectV2FieldCommon",
    id = "due",
    name = "Due",
    dataType = "DATE",
  }
end

local function builtin_field(name, data_type)
  return {
    __typename = "ProjectV2FieldCommon",
    id = "builtin-" .. name,
    name = name,
    dataType = data_type,
  }
end

local function default_fields()
  return {
    status_field(),
    notes_field(),
    estimate_field(),
    due_field(),
    builtin_field("Title", "TITLE"),
    builtin_field("Assignees", "ASSIGNEES"),
  }
end

local function detail_response(number, title, fields, item_count)
  return {
    data = {
      user = {
        projectV2 = {
          id = "P" .. number,
          number = number,
          title = title,
          url = "https://github.com/users/alice/projects/" .. number,
          public = true,
          closed = false,
          items = { totalCount = item_count or 3 },
          fields = { nodes = fields or default_fields() },
          views = {
            nodes = {
              { number = 1, name = "Board", layout = "BOARD_LAYOUT", filter = "" },
            },
          },
        },
      },
    },
  }
end

local function issue_content(number, title)
  return {
    __typename = "Issue",
    number = number,
    title = title,
    state = "OPEN",
    url = "https://github.com/a/r/issues/" .. number,
    repository = { nameWithOwner = "a/r" },
    labels = { totalCount = 0, nodes = {} },
    assignees = { totalCount = 0, nodes = {} },
    subIssuesSummary = vim.NIL,
    closedByPullRequestsReferences = vim.NIL,
  }
end

local function pr_content(number, title)
  return {
    __typename = "PullRequest",
    number = number,
    title = title,
    state = "OPEN",
    url = "https://github.com/a/r/pull/" .. number,
    repository = { nameWithOwner = "a/r" },
    labels = { totalCount = 0, nodes = {} },
    assignees = { totalCount = 0, nodes = {} },
  }
end

local function draft_content(title, body)
  return { __typename = "DraftIssue", title = title, body = body }
end

local function item_node(opts)
  local values = {}
  if opts.option then
    values[#values + 1] = {
      __typename = "ProjectV2ItemFieldSingleSelectValue",
      name = opts.option_name or opts.option,
      optionId = opts.option,
      field = { id = "status", name = "Status", dataType = "SINGLE_SELECT" },
    }
  end
  if opts.text ~= nil then
    values[#values + 1] = {
      __typename = "ProjectV2ItemFieldTextValue",
      text = opts.text,
      field = { id = "notes", name = "Notes", dataType = "TEXT" },
    }
  end
  if opts.number ~= nil then
    values[#values + 1] = {
      __typename = "ProjectV2ItemFieldNumberValue",
      number = opts.number,
      field = { id = "estimate", name = "Estimate", dataType = "NUMBER" },
    }
  end
  if opts.date ~= nil then
    values[#values + 1] = {
      __typename = "ProjectV2ItemFieldDateValue",
      date = opts.date,
      field = { id = "due", name = "Due", dataType = "DATE" },
    }
  end
  return {
    id = opts.id,
    type = opts.type,
    isArchived = opts.archived or false,
    content = opts.content,
    fieldValues = { nodes = values },
  }
end

local function default_items()
  return {
    item_node({
      id = "I1",
      type = "ISSUE",
      option = "todo",
      option_name = "Todo",
      text = "note",
      number = 3,
      date = "2026-01-05",
      content = issue_content(1, "Fix bug"),
    }),
    item_node({
      id = "I2",
      type = "PULL_REQUEST",
      option = "doing",
      option_name = "In Progress",
      content = pr_content(2, "Add feature"),
    }),
    item_node({
      id = "I3",
      type = "DRAFT_ISSUE",
      option = "todo",
      option_name = "Todo",
      content = draft_content("Draft idea", "draft body"),
    }),
  }
end

local function items_response(nodes, total_count, has_next, cursor)
  return {
    data = {
      user = {
        projectV2 = {
          items = {
            totalCount = total_count or #nodes,
            pageInfo = { hasNextPage = has_next or false, endCursor = cursor or vim.NIL },
            nodes = nodes,
          },
        },
      },
    },
  }
end

local function update_response(id)
  return { data = { updateProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
end

local function clear_response(id)
  return { data = { clearProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
end

local function open_board(number)
  board.open({
    owner = { host = "github.com", owner = "alice", type = "User" },
    number = number,
    parent_win = vim.api.nvim_get_current_win(),
  })
end

local function open_board_view(number, fields, nodes)
  open_board(number or 1)
  respond(1, detail_response(number or 1, "Board", fields))
  respond(2, items_response(nodes or default_items()))
  return current_window("gh-projects-board")
end

local function open_editor()
  key("ghe")
  local win, buf = current_window("gh-projects-editor")
  assert.is_not_nil(win)
  return win, buf
end

local function editor_header(win)
  return lines_of(win)[1]
end

describe("projects field edit", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    config.set({ group_by = "Status", column_width = 36, max_items = 1000 })
    fake_gh()
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    restore_gh()
    close_all()
    vim.o.columns, vim.o.lines = columns, lines
    config.set({ group_by = "Status", column_width = 36, max_items = 1000 })
  end)

  it("shows the editable fields and current values for the selected item", function()
    local board_win, board_buf = open_board_view()
    local editor_win, editor_buf = open_editor()

    assert.equals("gh-projects-editor", vim.bo[editor_buf].filetype)
    assert.is_false(vim.bo[editor_buf].modifiable)
    assert.is_true(vim.bo[editor_buf].readonly)
    local window = vim.api.nvim_win_get_config(editor_win)
    assert.equals("editor", window.relative)
    assert.equals(59, window.width)
    assert.equals(22, window.height)
    assert.equals(8, window.row)
    assert.equals(29, window.col)
    assert.same({
      "Fields for #1 Fix bug",
      "Status  Todo",
      "Notes  note",
      "Estimate  3",
      "Due  2026-01-05",
    }, lines_of(editor_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    assert.same({
      { 0, 0, #"Fields for #1 Fix bug", "GitHubProjectsHeader" },
      { 1, 0, #"Status  Todo", "GitHubProjectsCardSelected" },
    }, highlights(editor_buf))
    for _, lhs in ipairs({ "j", "k", "<CR>", "q", "<Esc>" }) do
      assert_mapping(editor_buf, "n", lhs)
    end

    key("j")
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    assert.same({
      { 0, 0, #"Fields for #1 Fix bug", "GitHubProjectsHeader" },
      { 1, 8, #"Status  Todo", "GitHubProjectsColorGray" },
      { 2, 0, #"Notes  note", "GitHubProjectsCardSelected" },
    }, highlights(editor_buf))
    assert.equals(board_win, current_window("gh-projects-board"))
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
    assert.equals(0, #notices)
  end)

  it("moves the field selection with j and k and stops at both ends", function()
    open_board_view()
    local editor_win = open_editor()

    key("k")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("j")
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("j")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("j")
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("j")
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("k")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("2j")
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(editor_win))
  end)

  it("applies a group single-select option and moves the item to the new column", function()
    local board_win, board_buf = open_board_view()
    local editor_win, editor_buf = open_editor()

    key("<CR>")
    local options_win, options_buf = options_window()
    assert.is_not_nil(options_win)
    assert.equals("", vim.bo[options_buf].filetype)
    assert.is_true(vim.bo[options_buf].modifiable)
    assert.is_false(vim.bo[options_buf].readonly)
    local window = vim.api.nvim_win_get_config(options_win)
    assert.equals(47, window.width)
    assert.equals(22, window.height)
    assert.equals(8, window.row)
    assert.equals(35, window.col)
    assert.same({
      "Status",
      "● Todo  ✓",
      "● In Progress",
      "● Done",
      "値を解除",
    }, lines_of(options_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(options_win))
    assert.same({
      { 0, 0, #"Status", "GitHubProjectsHeader" },
      { 1, 0, #"● Todo  ✓", "GitHubProjectsCardSelected" },
      { 2, 0, #"● In Progress", "GitHubProjectsColorBlue" },
      { 3, 0, #"● Done", "GitHubProjectsColorGreen" },
    }, highlights(options_buf))
    for _, lhs in ipairs({ "j", "k", "<CR>", "q", "<Esc>", "<C-C>" }) do
      assert_mapping(options_buf, "n", lhs)
    end

    key("j")
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(options_win))
    assert.same({
      { 0, 0, #"Status", "GitHubProjectsHeader" },
      { 1, 0, #"● Todo  ✓", "GitHubProjectsColorGray" },
      { 2, 0, #"● In Progress", "GitHubProjectsCardSelected" },
      { 3, 0, #"● Done", "GitHubProjectsColorGreen" },
    }, highlights(options_buf))

    key("<CR>")
    assert.equals(3, #pending)
    assert.same({
      projectId = "P1",
      itemId = "I1",
      fieldId = "status",
      value = { singleSelectOptionId = "doing" },
    }, variables(3))
    assert.equals("Updating...", editor_header(editor_win))
    assert.same({
      { 0, 0, #"Updating...", "GitHubProjectsLoading" },
      { 1, 0, #"Status  Todo", "GitHubProjectsCardSelected" },
    }, highlights(editor_buf))

    respond(3, update_response("I1"))
    assert.is_nil(options_window())
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.same({
      "Fields for #1 Fix bug",
      "Status  In Progress",
      "Notes  note",
      "Estimate  3",
      "Due  2026-01-05",
    }, lines_of(editor_win))
    assert.same({
      { 0, 0, #"Fields for #1 Fix bug", "GitHubProjectsHeader" },
      { 1, 0, #"Status  In Progress", "GitHubProjectsCardSelected" },
    }, highlights(editor_buf))
    assert.same({ column_index = 2, item_id = "I1" }, board.state(board_buf).selected)
    assert.equals("I1", board.state(board_buf).columns[2].items[1].id)
    assert.equals(1, board.state(board_buf).columns[1].count)
    assert.equals("I3", board.state(board_buf).columns[1].items[1].id)
    assert.equals(3, #calls)
    assert.equals(board_win, current_window("gh-projects-board"))
  end)

  it("clears a group single-select and moves the item to the no-value column", function()
    local board_win, board_buf = open_board_view()
    local editor_win = open_editor()

    key("<CR>")
    local options_win = options_window()
    key("jjj")
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(options_win))
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "status" }, variables(3))
    respond(3, clear_response("I1"))

    assert.is_nil(options_window())
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.same({
      "Fields for #1 Fix bug",
      "Status  未設定",
      "Notes  note",
      "Estimate  3",
      "Due  2026-01-05",
    }, lines_of(editor_win))
    local state = board.state(board_buf)
    assert.same({ column_index = 4, item_id = "I1" }, state.selected)
    assert.equals("I1", state.columns[4].items[1].id)
    assert.equals(1, state.columns[4].count)
    assert.equals(1, state.columns[1].count)
    assert.equals("I3", state.columns[1].items[1].id)
    assert.is_nil(board.selected_item(board_buf).values.status)
    assert.equals(board_win, current_window("gh-projects-board"))
  end)

  it("updates only the selected text, number and date field", function()
    local board_win, board_buf = open_board_view()
    local editor_win = open_editor()

    key("j")
    key("<CR>")
    local input_win, input_buf = current_window("gh-projects-input")
    assert.is_not_nil(input_win)
    assert.equals("gh-projects-input", vim.bo[input_buf].filetype)
    assert.is_true(vim.bo[input_buf].modifiable)
    assert.is_false(vim.bo[input_buf].readonly)
    local window = vim.api.nvim_win_get_config(input_win)
    assert.equals(59, window.width)
    assert.equals(1, window.height)
    assert.equals(18, window.row)
    assert.equals(29, window.col)
    assert.same({ { "Notes (Text)", "FloatTitle" } }, window.title)
    assert.same({ "note" }, lines_of(input_win))
    assert.same({ 1, 3 }, vim.api.nvim_win_get_cursor(input_win))
    for _, lhs in ipairs({ "<CR>", "<C-C>", "q", "<Esc>" }) do
      assert_mapping(input_buf, "n", lhs)
    end
    for _, lhs in ipairs({ "<CR>", "<C-C>" }) do
      assert_mapping(input_buf, "i", lhs)
    end

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "updated" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "notes", value = { text = "updated" } }, variables(3))
    assert.equals("Updating...", editor_header(editor_win))
    respond(3, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.equals("Notes  updated", lines_of(editor_win)[3])
    assert.equals("updated", board.selected_item(board_buf).values.notes.value)
    assert.equals("todo", board.selected_item(board_buf).values.status.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
    assert.equals(board_win, current_window("gh-projects-board"))

    key("j")
    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    assert.same({ { "Estimate (Number)", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    assert.same({ "3" }, lines_of(input_win))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "2.5" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate", value = { number = 2.5 } }, variables(4))
    respond(4, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Estimate  2.5", lines_of(editor_win)[4])
    assert.equals(2.5, board.selected_item(board_buf).values.estimate.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)

    key("j")
    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    assert.same({ { "Due (Date)", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    assert.same({ "2026-01-05" }, lines_of(input_win))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "2024-02-29" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "due", value = { date = "2024-02-29" } }, variables(5))
    respond(5, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Due  2024-02-29", lines_of(editor_win)[5])
    assert.equals("2024-02-29", board.selected_item(board_buf).values.due.value)
    assert.equals("updated", board.selected_item(board_buf).values.notes.value)
    assert.equals(2.5, board.selected_item(board_buf).values.estimate.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)

    key("k")
    key("k")
    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    assert.same({ { "Notes (Text)", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    assert.same({ "updated" }, lines_of(input_win))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "日本語のテキスト" })
    key("<CR>")
    assert.same({
      projectId = "P1",
      itemId = "I1",
      fieldId = "notes",
      value = { text = "日本語のテキスト" },
    }, variables(6))
    respond(6, update_response("I1"))
    assert.equals("Notes  日本語のテキスト", lines_of(editor_win)[3])
    assert.equals("日本語のテキスト", board.selected_item(board_buf).values.notes.value)

    local long = string.rep("a", 300)
    key("<CR>")
    input_buf = select(2, current_window("gh-projects-input"))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { long })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "notes", value = { text = long } }, variables(7))
    respond(7, update_response("I1"))
    assert.equals("Notes  " .. long, lines_of(editor_win)[3])
    assert.equals(long, board.selected_item(board_buf).values.notes.value)
    assert.equals("2024-02-29", board.selected_item(board_buf).values.due.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
  end)

  it("accepts a large finite number", function()
    local _, board_buf = open_board_view()
    local editor_win = open_editor()

    key("jj")
    key("<CR>")
    local input_buf = select(2, current_window("gh-projects-input"))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "1e308" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate", value = { number = 1e308 } }, variables(3))
    respond(3, update_response("I1"))
    assert.equals("Estimate  1e+308", lines_of(editor_win)[4])
    assert.equals(1e308, board.selected_item(board_buf).values.estimate.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
  end)

  it("clears text, number and date fields with an empty input", function()
    local _, board_buf = open_board_view()
    local editor_win = open_editor()

    key("j")
    key("<CR>")
    local input_buf = select(2, current_window("gh-projects-input"))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "notes" }, variables(3))
    respond(3, clear_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Notes  未設定", lines_of(editor_win)[3])
    assert.is_nil(board.selected_item(board_buf).values.notes)

    key("j")
    key("<CR>")
    input_buf = select(2, current_window("gh-projects-input"))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate" }, variables(4))
    respond(4, clear_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Estimate  未設定", lines_of(editor_win)[4])
    assert.is_nil(board.selected_item(board_buf).values.estimate)

    key("j")
    key("<CR>")
    input_buf = select(2, current_window("gh-projects-input"))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "due" }, variables(5))
    respond(5, clear_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Due  未設定", lines_of(editor_win)[5])
    assert.is_nil(board.selected_item(board_buf).values.due)
    assert.equals("todo", board.selected_item(board_buf).values.status.value)
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
  end)

  it("rejects invalid numbers and dates without sending and keeps the input", function()
    local _, board_buf = open_board_view()
    local editor_win = open_editor()

    key("j")
    key("j")
    key("<CR>")
    local input_win, input_buf = current_window("gh-projects-input")
    assert.same({ { "Estimate (Number)", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    local function invalid_number(text)
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { text })
      key("<CR>")
      assert.equals(2, #pending)
      assert.same({ text }, lines_of(input_win))
      assert.same({
        { "Estimate (Number)", "FloatTitle" },
        { "  Error: number value must be finite", "GitHubProjectsError" },
      }, vim.api.nvim_win_get_config(input_win).title)
      assert.equals("Error: number value must be finite", editor_header(editor_win))
    end
    invalid_number("abc")
    invalid_number("nan")
    invalid_number("inf")
    invalid_number("1e999")

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "-2" })
    key("<CR>")
    assert.equals(3, #pending)
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate", value = { number = -2 } }, variables(3))
    respond(3, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Estimate  -2", lines_of(editor_win)[4])
    assert.equals("Fields for #1 Fix bug", editor_header(editor_win))

    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "0.5" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate", value = { number = 0.5 } }, variables(4))
    respond(4, update_response("I1"))
    assert.equals("Estimate  0.5", lines_of(editor_win)[4])

    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "0" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "estimate", value = { number = 0 } }, variables(5))
    respond(5, update_response("I1"))
    assert.equals("Estimate  0", lines_of(editor_win)[4])
    assert.equals(0, board.selected_item(board_buf).values.estimate.value)

    key("j")
    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    assert.same({ { "Due (Date)", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    local function invalid_date(text)
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { text })
      key("<CR>")
      assert.equals(5, #pending)
      assert.same({ text }, lines_of(input_win))
      assert.same({
        { "Due (Date)", "FloatTitle" },
        { "  Error: date value must be YYYY-MM-DD and exist", "GitHubProjectsError" },
      }, vim.api.nvim_win_get_config(input_win).title)
      assert.equals("Error: date value must be YYYY-MM-DD and exist", editor_header(editor_win))
    end
    invalid_date("2026-02-30")
    invalid_date("2026-02-29")
    invalid_date("0000-01-01")
    invalid_date("2026-1-5")
    invalid_date("2026-04-31")

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "9999-12-31" })
    key("<CR>")
    assert.equals(6, #pending)
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "due", value = { date = "9999-12-31" } }, variables(6))
    respond(6, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Due  9999-12-31", lines_of(editor_win)[5])

    key("<CR>")
    input_win, input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "2024-02-29" })
    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "due", value = { date = "2024-02-29" } }, variables(7))
    respond(7, update_response("I1"))
    assert.equals("Due  2024-02-29", lines_of(editor_win)[5])
    assert.equals("2024-02-29", board.selected_item(board_buf).values.due.value)
    assert.equals(0, board.selected_item(board_buf).values.estimate.value)
  end)

  it("keeps the options screen, board and input when an update fails", function()
    local board_win, board_buf = open_board_view()
    local editor_win = open_editor()

    key("<CR>")
    local options_win = options_window()
    key("j")
    key("<CR>")
    graphql_error(3, "Could not resolve to a node with the global id of 'I1'")
    assert.is_not_nil(options_window())
    assert.equals(options_win, options_window())
    assert.equals("Error: Could not resolve to a node with the global id of 'I1'", lines_of(options_win)[1])
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(options_win))
    assert.equals("Error: Could not resolve to a node with the global id of 'I1'", editor_header(editor_win))
    local state = board.state(board_buf)
    assert.same({ column_index = 1, item_id = "I1" }, state.selected)
    assert.equals("todo", board.selected_item(board_buf).values.status.value)
    assert.equals(2, state.columns[1].count)
    assert.equals(1, state.columns[2].count)
    assert.equals(3, #calls)

    key("q")
    assert.is_nil(options_window())
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.equals("Status  Todo", lines_of(editor_win)[2])
    key("q")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.equals(2, board.state(board_buf).columns[1].count)

    open_editor()
    key("j")
    key("<CR>")
    local input_win, input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "changed" })
    key("<CR>")
    fail(4, 1, "HTTP 403")
    assert.is_not_nil(current_window("gh-projects-input"))
    assert.same({ "changed" }, lines_of(input_win))
    assert.same({
      { "Notes (Text)", "FloatTitle" },
      { "  Error: GitHub request failed (exit 1): HTTP 403", "GitHubProjectsError" },
    }, vim.api.nvim_win_get_config(input_win).title)
    assert.equals(
      "Error: GitHub request failed (exit 1): HTTP 403",
      editor_header(current_window("gh-projects-editor"))
    )
    assert.equals("note", board.selected_item(board_buf).values.notes.value)
    assert.equals(4, #calls)

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "retry" })
    key("<CR>")
    assert.equals(5, #calls)
    respond(5, update_response("I1"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Notes  retry", lines_of(current_window("gh-projects-editor"))[3])
    assert.equals("retry", board.selected_item(board_buf).values.notes.value)
    assert.equals("Fields for #1 Fix bug", editor_header(current_window("gh-projects-editor")))
  end)

  it("shows No editable fields when only built-in fields exist", function()
    open_board_view(1, { builtin_field("Title", "TITLE"), builtin_field("Assignees", "ASSIGNEES") })
    local editor_win, editor_buf = open_editor()

    assert.same({ "Fields for #1 Fix bug", "No editable fields" }, lines_of(editor_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    assert.same({
      { 0, 0, #"Fields for #1 Fix bug", "GitHubProjectsHeader" },
    }, highlights(editor_buf))
    key("j")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("k")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))
    key("<CR>")
    assert.is_nil(options_window())
    assert.is_nil(current_window("gh-projects-input"))
    key("q")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_not_nil(current_window("gh-projects-board"))
  end)

  it("closes the field editor and its children when the board closes", function()
    local parent = vim.api.nvim_get_current_win()
    open_board_view()
    open_editor()
    key("<CR>")
    assert.is_not_nil(options_window())

    float.close("projects-board:github.com:alice:1")
    assert.is_nil(current_window("gh-projects-board"))
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_nil(options_window())
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())

    fake_gh()
    open_board_view()
    open_editor()
    key("<CR>")
    key("j")
    key("<CR>")
    assert.equals(3, #pending)
    float.close("projects-board:github.com:alice:1")
    respond(3, update_response("I1"))
    assert.equals(0, #float_windows())
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.equals(0, #notices)
  end)

  it("shows the last accepted value when the same field changes consecutively", function()
    local _, board_buf = open_board_view()
    local editor_win = open_editor()

    key("<CR>")
    key("j")
    key("<CR>")
    respond(3, update_response("I1"))
    assert.equals("Status  In Progress", lines_of(editor_win)[2])
    assert.same({ column_index = 2, item_id = "I1" }, board.state(board_buf).selected)

    key("<CR>")
    key("j")
    key("<CR>")
    respond(4, update_response("I1"))
    assert.equals("Status  Done", lines_of(editor_win)[2])
    assert.same({ column_index = 3, item_id = "I1" }, board.state(board_buf).selected)
    assert.equals("done", board.selected_item(board_buf).values.status.value)
    assert.equals(4, #calls)

    key("<CR>")
    local options_win = options_window()
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(options_win))
    key("<CR>")
    assert.is_nil(options_window())
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.equals("Status  Done", lines_of(editor_win)[2])
    assert.equals(4, #calls)
    assert.equals(4, #pending)
  end)

  it("reuses the editor for the selected item", function()
    local board_win, board_buf = open_board_view()
    local editor_win, editor_buf = open_editor()
    local first = { editor_win, editor_buf }

    vim.api.nvim_set_current_win(board_win)
    key("l")
    assert.same({ column_index = 2, item_id = "I2" }, board.state(board_buf).selected)
    key("ghe")
    assert.same(first, { current_window("gh-projects-editor") })
    assert.same({
      "Fields for #2 Add feature",
      "Status  In Progress",
      "Notes  未設定",
      "Estimate  未設定",
      "Due  未設定",
    }, lines_of(editor_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(editor_win))

    vim.api.nvim_set_current_win(board_win)
    key("h")
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
    key("j")
    assert.same({ column_index = 1, item_id = "I3" }, board.state(board_buf).selected)
    key("ghe")
    assert.same(first, { current_window("gh-projects-editor") })
    assert.same({
      "Fields for Draft idea",
      "Status  Todo",
      "Notes  未設定",
      "Estimate  未設定",
      "Due  未設定",
    }, lines_of(editor_win))
    assert.equals(1, #vim.tbl_filter(function(win)
      return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "gh-projects-editor"
    end, float_windows()))
  end)

  it("does not open the editor when no item is selected", function()
    open_board_view()
    key("l")
    key("l")
    local board_buf = select(2, current_window("gh-projects-board"))
    assert.same({ column_index = 3, item_id = nil }, board.state(board_buf).selected)
    key("ghe")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.same({ "GitHub projects: select an item first", vim.log.levels.ERROR }, notices[1])
    assert.is_not_nil(current_window("gh-projects-board"))
  end)

  it("shows an unknown single-select value and still applies another option", function()
    local nodes = {
      item_node({
        id = "I1",
        type = "ISSUE",
        option = "archived",
        option_name = "Archived",
        content = issue_content(1, "Fix bug"),
      }),
      item_node({
        id = "I2",
        type = "PULL_REQUEST",
        option = "doing",
        option_name = "In Progress",
        content = pr_content(2, "Add feature"),
      }),
      item_node({
        id = "I3",
        type = "DRAFT_ISSUE",
        option = "todo",
        option_name = "Todo",
        content = draft_content("Draft idea", "draft body"),
      }),
    }
    local fields = {
      status_field({
        { id = "todo", name = "Todo", color = "GRAY" },
        { id = "doing", name = "In Progress", color = "BLUE" },
      }),
    }
    local board_win, board_buf = open_board_view(1, fields, nodes)
    assert.same({ column_index = 1, item_id = "I3" }, board.state(board_buf).selected)
    assert.equals("I1", board.state(board_buf).columns[3].items[1].id)

    key("l")
    key("l")
    assert.same({ column_index = 3, item_id = "I1" }, board.state(board_buf).selected)
    local editor_win = open_editor()
    assert.equals("Status  不明 (archived)", lines_of(editor_win)[2])

    key("<CR>")
    local options_win, options_buf = options_window()
    assert.same({ "Status", "● Todo", "● In Progress", "値を解除" }, lines_of(options_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(options_win))
    assert.same({
      { 0, 0, #"Status", "GitHubProjectsHeader" },
      { 1, 0, #"● Todo", "GitHubProjectsCardSelected" },
      { 2, 0, #"● In Progress", "GitHubProjectsColorBlue" },
    }, highlights(options_buf))

    key("j")
    key("<CR>")
    assert.same({
      projectId = "P1",
      itemId = "I1",
      fieldId = "status",
      value = { singleSelectOptionId = "doing" },
    }, variables(3))
    respond(3, update_response("I1"))
    assert.is_nil(options_window())
    assert.equals("Status  In Progress", lines_of(editor_win)[2])
    assert.same({ column_index = 2, item_id = "I1" }, board.state(board_buf).selected)
    assert.equals(board_win, current_window("gh-projects-board"))
  end)

  it("shows only the clear row when a single-select field has no options", function()
    local nodes = {
      item_node({
        id = "I1",
        type = "ISSUE",
        option = "archived",
        option_name = "Archived",
        content = issue_content(1, "Fix bug"),
      }),
    }
    open_board_view(1, { status_field({}) }, nodes)
    local board_buf = select(2, current_window("gh-projects-board"))
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)
    local editor_win = open_editor()
    assert.equals("Status  不明 (archived)", lines_of(editor_win)[2])

    key("<CR>")
    local options_win, options_buf = options_window()
    assert.same({ "Status", "値を解除" }, lines_of(options_win))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(options_win))
    assert.same({
      { 0, 0, #"Status", "GitHubProjectsHeader" },
      { 1, 0, #"値を解除", "GitHubProjectsCardSelected" },
    }, highlights(options_buf))

    key("<CR>")
    assert.same({ projectId = "P1", itemId = "I1", fieldId = "status" }, variables(3))
    respond(3, clear_response("I1"))
    assert.is_nil(options_window())
    assert.equals("Status  未設定", lines_of(editor_win)[2])
    assert.same({ column_index = 1, item_id = "I1" }, board.state(board_buf).selected)

    key("<CR>")
    options_window()
    key("<CR>")
    assert.is_nil(options_window())
    assert.equals(3, #pending)
    assert.equals(3, #calls)
  end)

  it("ignores an old response after the editor is reused for another item", function()
    local board_win, board_buf = open_board_view()
    open_editor()
    key("<CR>")
    key("j")
    key("<CR>")
    assert.equals(3, #pending)
    key("q")
    assert.is_nil(options_window())

    vim.api.nvim_set_current_win(board_win)
    key("l")
    assert.same({ column_index = 2, item_id = "I2" }, board.state(board_buf).selected)
    key("ghe")
    local editor_win = current_window("gh-projects-editor")
    assert.equals("Fields for #2 Add feature", lines_of(editor_win)[1])
    assert.equals("Status  In Progress", lines_of(editor_win)[2])

    respond(3, update_response("I1"))
    assert.equals("Fields for #2 Add feature", lines_of(editor_win)[1])
    assert.equals("Status  In Progress", lines_of(editor_win)[2])
    assert.equals("todo", board.state(board_buf).items[1].values.status.value)
    assert.same({ column_index = 2, item_id = "I2" }, board.state(board_buf).selected)
    assert.equals(3, #calls)
  end)

  it("does not update screens in another tab and keeps the current tab", function()
    local _, board_buf = open_board_view()
    open_editor()
    key("<CR>")
    key("j")
    key("<CR>")
    assert.equals(3, #pending)

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_win = vim.api.nvim_get_current_win()
    respond(3, update_response("I1"))

    assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(other_win, vim.api.nvim_get_current_win())
    assert.is_nil(options_window())

    vim.cmd("tabnext 1")
    local editor_win = current_window("gh-projects-editor")
    assert.equals("Status  In Progress", lines_of(editor_win)[2])
    assert.same({ column_index = 2, item_id = "I1" }, board.state(board_buf).selected)
  end)

  it("cancels options and input screens with q, Escape and CTRL-C", function()
    open_board_view()
    local editor_win = open_editor()

    for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
      key("<CR>")
      assert.is_not_nil(options_window())
      key(lhs)
      assert.is_nil(options_window())
      assert.equals(editor_win, vim.api.nvim_get_current_win())
    end

    key("j")
    for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
      key("<CR>")
      assert.is_not_nil(current_window("gh-projects-input"))
      key(lhs)
      assert.is_nil(current_window("gh-projects-input"))
      assert.equals(editor_win, vim.api.nvim_get_current_win())
    end
    assert.equals(2, #pending)
    assert.equals(2, #calls)
    key("<Esc>")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_not_nil(current_window("gh-projects-board"))
  end)

  it("closes the editor and its children when q is pressed on the board", function()
    local parent = vim.api.nvim_get_current_win()
    local board_win = select(1, open_board_view())
    open_editor()
    key("<CR>")
    assert.is_not_nil(options_window())

    vim.api.nvim_set_current_win(board_win)
    key("q")
    assert.is_nil(current_window("gh-projects-board"))
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_nil(options_window())
    assert.equals(parent, vim.api.nvim_get_current_win())
  end)

  it("ignores a second submit while an update is in flight", function()
    open_board_view()
    open_editor()
    key("<CR>")
    key("j")
    key("<CR>")
    assert.equals(3, #pending)
    key("<CR>")
    assert.equals(3, #pending)
    assert.equals(3, #calls)
    respond(3, update_response("I1"))
    assert.is_nil(options_window())
  end)

  it("closes the options and input screens when the editor closes", function()
    open_board_view()
    open_editor()
    key("<CR>")
    assert.is_not_nil(options_window())
    float.close("projects-fields:P1")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_nil(options_window())
    assert.is_not_nil(current_window("gh-projects-board"))

    key("ghe")
    key("j")
    key("<CR>")
    assert.is_not_nil(current_window("gh-projects-input"))
    float.close("projects-fields:P1")
    assert.is_nil(current_window("gh-projects-editor"))
    assert.is_nil(current_window("gh-projects-input"))
    assert.is_not_nil(current_window("gh-projects-board"))
  end)
end)
