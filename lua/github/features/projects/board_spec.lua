local process = require("github.core.process")
local config = require("github.core.config")
local board = require("github.features.projects.board")
local links_copy = require("github.features.links.copy")

local old_run, old_notify, old_copy_write
local calls, pending, notices, copied

local function fake_gh()
  calls, pending, notices, copied = {}, {}, {}, nil
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

local function list_lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function highlights(buf, group)
  local values = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
  do
    if not group or mark[4].hl_group == group then
      values[#values + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group, mark[4].priority }
    end
  end
  return values
end

local function column_offset(_, buf)
  local marks = highlights(buf, "GitHubProjectsColumnSelected")
  if #marks > 0 then
    return marks[1][2]
  end
  marks = highlights(buf, "GitHubProjectsCardSelectedBorder")
  return marks[1] and marks[1][2] or 0
end

local function find_line(win, text)
  for index, line in ipairs(list_lines(win)) do
    if line:find(text, 1, true) then
      return index
    end
  end
end

local function assert_card_cursor(win, _, title)
  local line = find_line(win, title)
  assert.is_not_nil(line, "missing card title: " .. title)
  local start = list_lines(win)[line]:find(title, 1, true)
  assert.is_not_nil(start, "missing title text: " .. title)
  assert.same({ line, start - 1 }, vim.api.nvim_win_get_cursor(win))
end

local function assert_header_cursor(win, buf)
  assert.same({ 2, column_offset(win, buf) }, vim.api.nvim_win_get_cursor(win))
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

local function status_field()
  return {
    __typename = "ProjectV2SingleSelectField",
    id = "status",
    name = "Status",
    dataType = "SINGLE_SELECT",
    options = {
      { id = "todo", name = "Todo", color = "GRAY" },
      { id = "doing", name = "In Progress", color = "BLUE" },
      { id = "done", name = "Done", color = "GREEN" },
      { id = "blocked", name = "Blocked", color = "RED" },
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

local function detail_response(number, title, filter, with_view, item_count)
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
          items = { totalCount = item_count or 4 },
          fields = { nodes = { status_field(), notes_field() } },
          views = with_view and {
            nodes = {
              { number = 1, name = "Board", layout = "BOARD_LAYOUT", filter = filter or "" },
            },
          } or { nodes = {} },
        },
      },
    },
  }
end

local function issue_content(number, title, labels, assignees, sub_issues, related)
  return {
    __typename = "Issue",
    number = number,
    title = title,
    state = "OPEN",
    url = "https://github.com/a/r/issues/" .. number,
    repository = { nameWithOwner = "a/r" },
    labels = labels or { totalCount = 0, nodes = {} },
    assignees = assignees or { totalCount = 0, nodes = {} },
    subIssuesSummary = sub_issues or vim.NIL,
    closedByPullRequestsReferences = related or vim.NIL,
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
  if opts.text then
    values[#values + 1] = {
      __typename = "ProjectV2ItemFieldTextValue",
      text = opts.text,
      field = { id = "notes", name = "Notes", dataType = "TEXT" },
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

local function empty_connection()
  return { totalCount = 0, nodes = {} }
end

local function default_items()
  return {
    item_node({
      id = "I1",
      type = "ISSUE",
      option = "todo",
      option_name = "Todo",
      content = issue_content(
        1,
        "Fix bug",
        { totalCount = 1, nodes = { { name = "bug", color = "ff0000" } } },
        { totalCount = 1, nodes = { { login = "alice" } } },
        { total = 2, completed = 1 },
        { totalCount = 1, nodes = { { number = 9, url = "https://github.com/a/r/pull/9" } } }
      ),
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
    item_node({ id = "R1", type = "REDACTED", option = "blocked", option_name = "Blocked", content = vim.NIL }),
  }
end

local function items_with_no_value()
  local items = default_items()
  items[#items + 1] = item_node({
    id = "N1",
    type = "ISSUE",
    content = issue_content(4, "Unsorted", empty_connection(), empty_connection()),
  })
  return items
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

local function open_board(number)
  board.open({
    owner = { host = "github.com", owner = "alice", type = "User" },
    number = number,
    parent_win = vim.api.nvim_get_current_win(),
  })
end

describe("projects board", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    fake_gh()
    old_copy_write = links_copy.write
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    restore_gh()
    links_copy.write = old_copy_write
    close_all()
    vim.o.columns, vim.o.lines = columns, lines
    config.set({ group_by = "Status", column_width = 36, max_items = 1000 })
  end)

  it("renders columns, cards and the initial selection", function()
    open_board(1)
    assert.equals(0, #float_windows())
    respond(1, detail_response(1, "Board"))
    local win, buf = current_window("gh-projects-board")
    assert.is_not_nil(win)
    assert.equals("FloatBorder:GitHubProjectsCardBorder", vim.wo[win].winhighlight)
    local loading = list_lines(win)
    assert.equals("Loading 0/4...", loading[1])
    assert.equals(vim.api.nvim_win_get_config(win).width, vim.fn.strdisplaywidth(loading[2]))
    assert.is_not_nil(loading[2]:find("● Todo 0", 1, true))
    assert.is_not_nil(loading[2]:find("● In Progress 0", 1, true))
    assert.equals("No items", loading[3])

    respond(2, items_response(default_items()))
    -- The detail and the first items page were requested in parallel, so the
    -- page is reused instead of requesting it again after the detail arrives.
    assert.equals(2, #pending)
    assert.same({ owner = "alice", number = 1, filter = "" }, vim.json.decode(calls[2].opts.stdin).variables)
    local rendered = list_lines(win)
    assert.equals("alice / Board  ·  4 items  ·  filter: ", rendered[1])
    assert.is_not_nil(rendered[2]:find("● Todo 2", 1, true))
    assert.is_not_nil(rendered[2]:find("● In Progress 1", 1, true))
    local text = table.concat(rendered, "\n")
    for _, expected in ipairs({
      "◉ r #1",
      "Fix bug",
      "alice",
      "bug",
      "1/2",
      "⇄ r #2",
      "Add feature",
      "✎ Draft idea",
    }) do
      assert.is_not_nil(text:find(expected, 1, true), expected)
    end
    assert.is_true(#rendered > 20)
    assert_card_cursor(win, buf, "Fix bug")

    local selected_border = highlights(buf, "GitHubProjectsCardSelectedBorder")
    assert.is_true(#selected_border >= 8)
    local selected = highlights(buf, "GitHubProjectsCardSelected")
    assert.is_true(#selected >= 3)
    for _, span in ipairs(selected) do
      assert.equals(3, span[2])
      assert.is_true(span[3] > 0)
      assert.is_true(span[3] <= #rendered[span[1] + 1])
    end
    local column_selected = highlights(buf, "GitHubProjectsColumnSelected")
    assert.is_true(#column_selected >= 1)
    assert.equals(1, column_selected[1][1])

    local state = board.state(buf)
    assert.same({
      "body_cache",
      "columns",
      "fields",
      "filter",
      "first_col",
      "generation",
      "group_field",
      "items",
      "offsets",
      "pagination",
      "project",
      "selected",
      "visible",
    }, vim.fn.sort(vim.tbl_keys(state)))
    assert.equals("Board", state.project.title)
    assert.equals(4, #state.items)
    assert.same({ 2, 1, 0, 1 }, {
      state.columns[1].count,
      state.columns[2].count,
      state.columns[3].count,
      state.columns[4].count,
    })
    assert.same({ "Todo", "In Progress", "Done", "Blocked" }, {
      state.columns[1].name,
      state.columns[2].name,
      state.columns[3].name,
      state.columns[4].name,
    })
    assert.same({ column_index = 1, item_id = "I1" }, state.selected)
    assert.same({ 1, 1, 1, 1 }, state.offsets)
    assert.equals("", state.filter)
    assert.is_nil(state.view)
    assert.is_nil(state.loading)
    assert.is_nil(state.error)
    assert.is_nil(state.truncated)
    assert.equals(1, state.first_col)
    assert.equals(2, state.visible)
    assert.equals(1, state.generation)
    assert.equals("status", state.group_field.id)
    assert.equals("I1", board.selected_item(buf).id)
    local keys = { "h", "l", "j", "k", "H", "L", "g", "G", "K", "<CR>", "<C-O>" }
    vim.list_extend(keys, { "ghy", "ghs", "ghe", "ghn", "ghd", "r", "?", "q", "<Esc>" })
    for _, lhs in ipairs(keys) do
      assert_mapping(buf, "n", lhs)
    end
  end)

  it("keeps the card highlights above the column background", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local _, buf = current_window("gh-projects-board")

    local function assert_priority(group, expected)
      local spans = highlights(buf, group)
      assert.is_true(#spans > 0, "missing " .. group)
      for _, span in ipairs(spans) do
        assert.equals(expected, span[5], group .. " priority")
      end
    end

    assert_priority("GitHubProjectsCardBorder", 10)
    assert_priority("GitHubProjectsCardSelectedBorder", 10)
    assert_priority("GitHubProjectsCard", 1)
    assert_priority("GitHubProjectsCardSelected", 1)
    assert_priority("GitHubProjectsCardTitle", 2)
    assert_priority("GitHubProjectsColumnBg", 0)
    assert_priority("GitHubProjectsColumn", 2)
    local header_above = false
    for _, span in ipairs(highlights(buf, "GitHubProjectsColumnHeader")) do
      if span[5] == 1 then
        header_above = true
      end
    end
    assert.is_true(header_above, "missing header highlight above the column background")
  end)

  it("names the no-value column after the group field", function()
    open_board(1)
    local detail = detail_response(1, "Board")
    local stage = status_field()
    stage.name = "Stage"
    detail.data.user.projectV2.fields.nodes = { stage }
    respond(1, detail)
    respond(2, items_response(items_with_no_value()))
    local _, buf = current_window("gh-projects-board")

    assert.equals("No Stage", board.state(buf).columns[1].name)
  end)

  it("puts the no-value column at the left edge and selects its first item", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(items_with_no_value()))
    local win, buf = current_window("gh-projects-board")
    local state = board.state(buf)

    assert.same(
      { "No Status", "Todo", "In Progress", "Done", "Blocked" },
      vim.tbl_map(function(column)
        return column.name
      end, state.columns)
    )
    assert.is_true(state.columns[1].no_value)
    assert.equals(" ○ No Status 1", list_lines(win)[2]:sub(1, #" ○ No Status 1"))
    assert.same({ column_index = 1, item_id = "N1" }, state.selected)
  end)

  it("hides the no-value column when no item lacks a group value", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    local state = board.state(buf)

    assert.same(
      { "Todo", "In Progress", "Done", "Blocked" },
      vim.tbl_map(function(column)
        return column.name
      end, state.columns)
    )
    assert.equals(" ● Todo 2", list_lines(win)[2]:sub(1, #" ● Todo 2"))
    assert.is_nil(list_lines(win)[2]:find("No Status", 1, true))
  end)

  it("keeps the only column of a project without a single-select field even when it is empty", function()
    open_board(1)
    local detail = detail_response(1, "Board")
    detail.data.user.projectV2.fields.nodes = { notes_field() }
    respond(1, detail)
    respond(2, items_response({}))
    local win, buf = current_window("gh-projects-board")
    local state = board.state(buf)

    assert.equals(1, #state.columns)
    assert.equals("No Status", state.columns[1].name)
    assert.is_not_nil(list_lines(win)[2]:find("○ No Status 0", 1, true))
  end)

  it("renders a single column when the project has no single-select field", function()
    open_board(1)
    local detail = detail_response(1, "Board")
    detail.data.user.projectV2.fields.nodes = { notes_field() }
    respond(1, detail)
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    local state = board.state(buf)

    assert.equals(1, #state.columns)
    assert.is_true(state.columns[1].no_value)
    assert.equals(4, state.columns[1].count)
    assert.is_not_nil(list_lines(win)[2]:find("○ No Status 4", 1, true))
    assert.same({ column_index = 1, item_id = "I1" }, state.selected)
    assert.is_not_nil(list_lines(win)[4]:find("◉ r #1", 1, true))
  end)

  it("moves between columns and items and stops at both ends", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")

    key("k")
    assert_card_cursor(win, buf, "Fix bug")
    key("j")
    key("j")
    assert_card_cursor(win, buf, "✎ Draft idea")
    assert.same({ column_index = 1, item_id = "I3" }, board.state(buf).selected)
    key("j")
    assert_card_cursor(win, buf, "✎ Draft idea")

    key("l")
    assert_card_cursor(win, buf, "Add feature")
    assert.same({ column_index = 2, item_id = "I2" }, board.state(buf).selected)
    key("j")
    assert_card_cursor(win, buf, "Add feature")

    key("l")
    assert_header_cursor(win, buf)
    assert.same({ column_index = 3, item_id = nil }, board.state(buf).selected)
    assert.equals(2, board.state(buf).first_col)
    assert.is_not_nil(find_line(win, "—"))
    assert.is_not_nil(find_line(win, "Add feature"))

    key("l")
    assert_card_cursor(win, buf, "[redacted]")
    assert.same({ column_index = 4, item_id = "R1" }, board.state(buf).selected)
    assert.equals(3, board.state(buf).first_col)

    key("h")
    assert_header_cursor(win, buf)
    assert.equals(3, board.state(buf).first_col)

    key("H")
    assert_card_cursor(win, buf, "Fix bug")
    assert.equals(1, board.state(buf).first_col)

    key("L")
    assert_card_cursor(win, buf, "[redacted]")
    assert.same({ column_index = 4, item_id = "R1" }, board.state(buf).selected)
    key("g")
    key("G")
    assert_card_cursor(win, buf, "[redacted]")
  end)

  it("scrolls a column to keep the selected card visible", function()
    vim.o.columns, vim.o.lines = 80, 24
    local nodes = {}
    for index = 1, 10 do
      nodes[index] = item_node({
        id = "D" .. index,
        type = "DRAFT_ISSUE",
        option = "todo",
        option_name = "Todo",
        content = draft_content("Draft " .. index, ""),
      })
    end
    open_board(1)
    respond(1, detail_response(1, "Board", nil, false, 10))
    respond(2, items_response(nodes, 10))
    local win, buf = current_window("gh-projects-board")

    key("G")
    assert.same({ column_index = 1, item_id = "D10" }, board.state(buf).selected)
    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.is_not_nil(list_lines(win)[cursor[1]]:find("✎ Draft 10", 1, true))
    assert.is_true(cursor[1] <= #list_lines(win))
    assert.is_true(board.state(buf).offsets[1] > 1)

    key("g")
    assert_card_cursor(win, buf, "✎ Draft 1")
    assert.equals(1, board.state(buf).offsets[1])
    assert.is_not_nil(list_lines(win)[4]:find("✎ Draft 1", 1, true))
  end)

  it("applies a filter from ghs and keeps the previous content on failure", function()
    open_board(1)
    respond(1, detail_response(1, "Board", "label:bug", true))
    -- The parallel first page uses no filter, so it is discarded and the
    -- filtered request runs after the detail arrives.
    respond(2, items_response(default_items()))
    respond(3, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    assert.equals("alice / Board  ·  4 items  ·  view: Board  ·  filter: label:bug", list_lines(win)[1])

    key("ghs")
    local input_win, input_buf = current_window("gh-projects-input")
    assert.is_not_nil(input_win)
    assert.same({ "label:bug" }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "assignee:alice" })
    key("<Esc>")
    key("<CR>")
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("Loading 4/4...", list_lines(win)[1])
    assert.equals("assignee:alice", vim.json.decode(calls[4].opts.stdin).variables.filter)

    respond(4, items_response({ default_items()[1] }))
    assert.equals("alice / Board  ·  1 items  ·  filter: assignee:alice", list_lines(win)[1])
    assert.is_nil(board.state(buf).view)
    assert.equals("assignee:alice", board.state(buf).filter)

    key("ghs")
    local _, bad_input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(bad_input_buf, 0, -1, false, { "bad" })
    key("<Esc>")
    key("<CR>")
    fail(5, 1, "HTTP 403")
    assert.equals("Error: GitHub request failed (exit 1): HTTP 403", list_lines(win)[1])
    assert.equals("assignee:alice", board.state(buf).filter)
    assert.equals(1, #board.state(buf).items)

    key("ghs")
    local _, none_input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(none_input_buf, 0, -1, false, { "none" })
    key("<Esc>")
    key("<CR>")
    respond(6, items_response({}))
    assert.equals("alice / Board  ·  0 items  ·  filter: none", list_lines(win)[1])
    assert.equals("No items match filter", list_lines(win)[3])
    assert.is_nil(board.state(buf).selected.item_id)

    key("ghs")
    local _, cancel_input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(cancel_input_buf, 0, -1, false, { "label:bug" })
    key("q")
    assert.is_nil(current_window("gh-projects-input"))
    assert.equals("alice / Board  ·  0 items  ·  filter: none", list_lines(win)[1])
    assert.equals("none", board.state(buf).filter)
    assert.equals(6, #pending)

    key("ghs")
    local _, empty_input_buf = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(empty_input_buf, 0, -1, false, { "" })
    key("<CR>")
    assert.equals("Loading 0/4...", list_lines(win)[1])
    respond(7, items_response(default_items()))
    assert.equals("alice / Board  ·  4 items  ·  filter: ", list_lines(win)[1])
    assert.equals("", board.state(buf).filter)
  end)

  it("previews an issue body and a draft body and caches fetched bodies", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local board_win = current_window("gh-projects-board")

    key("K")
    local preview_win, preview_buf = current_window("gh-projects-preview")
    assert.is_not_nil(preview_win)
    assert.same({ "Loading body..." }, list_lines(preview_win))
    assert.equals("gh-projects-preview", vim.bo[preview_buf].filetype)
    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body text" } } } })
    assert.same({ "Issue #1 Fix bug", "Body text" }, list_lines(preview_win))

    vim.api.nvim_set_current_win(board_win)
    key("K")
    assert.same({ "Issue #1 Fix bug", "Body text" }, list_lines(preview_win))
    assert.equals(3, #pending)

    vim.api.nvim_set_current_win(preview_win)
    key("q")
    assert.is_nil(current_window("gh-projects-preview"))

    vim.api.nvim_set_current_win(board_win)
    key("j")
    key("K")
    local draft_win = current_window("gh-projects-preview")
    assert.same({ "Draft issue Draft idea", "draft body" }, list_lines(draft_win))
    assert.equals(3, #pending)
  end)

  it("shows a preview failure and keeps the board selection", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")

    key("K")
    local preview_win = current_window("gh-projects-preview")
    fail(3, 1, "HTTP 500")
    assert.same({ "Error: GitHub request failed (exit 1): HTTP 500" }, list_lines(preview_win))
    assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
    assert.equals(win, current_window("gh-projects-board"))

    vim.api.nvim_set_current_win(preview_win)
    key("q")
    assert.is_nil(current_window("gh-projects-preview"))
  end)

  it("updates the preview that started the body request when another tab has the same preview", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))

    key("K")
    local first_preview = current_window("gh-projects-preview")
    assert.same({ "Loading body..." }, list_lines(first_preview))

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    open_board(1)
    respond(4, detail_response(1, "Board"))
    respond(5, items_response(default_items()))
    key("K")
    local second_preview = current_window("gh-projects-preview")
    assert.same({ "Loading body..." }, list_lines(second_preview))

    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body from tab1" } } } })
    assert.same({ "Issue #1 Fix bug", "Body from tab1" }, list_lines(first_preview))
    assert.same({ "Loading body..." }, list_lines(second_preview))
    assert.equals(second_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(second_preview, vim.api.nvim_get_current_win())

    respond(6, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body from tab2" } } } })
    assert.same({ "Issue #1 Fix bug", "Body from tab2" }, list_lines(second_preview))
    assert.same({ "Issue #1 Fix bug", "Body from tab1" }, list_lines(first_preview))
  end)

  it("updates the preview that started the body request after switching to a tab without it", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))

    key("K")
    local preview = current_window("gh-projects-preview")
    assert.same({ "Loading body..." }, list_lines(preview))

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_win = vim.api.nvim_get_current_win()

    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body text" } } } })
    assert.same({ "Issue #1 Fix bug", "Body text" }, list_lines(preview))
    assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(other_win, vim.api.nvim_get_current_win())
  end)

  it("discards the earlier body response when the same preview is requested again", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local board_win = current_window("gh-projects-board")

    key("K")
    local preview = vim.api.nvim_get_current_win()
    assert.same({ "Loading body..." }, list_lines(preview))
    vim.api.nvim_set_current_win(board_win)
    key("K")
    assert.equals(preview, vim.api.nvim_get_current_win())
    assert.same({ "Loading body..." }, list_lines(preview))
    assert.equals(4, #pending)

    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Stale body" } } } })
    assert.same({ "Loading body..." }, list_lines(preview))

    respond(4, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Fresh body" } } } })
    assert.same({ "Issue #1 Fix bug", "Fresh body" }, list_lines(preview))
  end)

  it("updates each preview when two items request their bodies at the same time", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(
      2,
      items_response({
        item_node({
          id = "I1",
          type = "ISSUE",
          option = "todo",
          option_name = "Todo",
          content = issue_content(1, "First issue", empty_connection(), empty_connection()),
        }),
        item_node({
          id = "I4",
          type = "ISSUE",
          option = "todo",
          option_name = "Todo",
          content = issue_content(4, "Second issue", empty_connection(), empty_connection()),
        }),
      }, 2)
    )
    local board_win = current_window("gh-projects-board")

    key("K")
    local first_preview = vim.api.nvim_get_current_win()
    assert.same({ "Loading body..." }, list_lines(first_preview))
    vim.api.nvim_set_current_win(board_win)
    key("j")
    key("K")
    local second_preview = vim.api.nvim_get_current_win()
    assert.is_true(first_preview ~= second_preview)
    assert.same({ "Loading body..." }, list_lines(second_preview))
    assert.equals(4, #pending)

    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body one" } } } })
    assert.same({ "Issue #1 First issue", "Body one" }, list_lines(first_preview))
    assert.same({ "Loading body..." }, list_lines(second_preview))

    respond(4, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body two" } } } })
    assert.same({ "Issue #4 Second issue", "Body two" }, list_lines(second_preview))
    assert.same({ "Issue #1 First issue", "Body one" }, list_lines(first_preview))
  end)

  it("discards the body response when the preview was closed before it arrives", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local board_win = current_window("gh-projects-board")

    key("K")
    local preview = current_window("gh-projects-preview")
    vim.api.nvim_set_current_win(preview)
    key("q")
    assert.is_nil(current_window("gh-projects-preview"))

    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Late body" } } } })
    assert.equals(3, #pending)
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.is_nil(current_window("gh-projects-preview"))

    key("K")
    local reopened = current_window("gh-projects-preview")
    assert.same({ "Loading body..." }, list_lines(reopened))
    assert.equals(4, #pending)
    respond(4, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Fresh body" } } } })
    assert.same({ "Issue #1 Fix bug", "Fresh body" }, list_lines(reopened))
  end)

  it("opens issues, pull requests and drafts and rejects redacted items", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local board_win = current_window("gh-projects-board")

    key("<CR>")
    respond(3, { data = { repository = { issue = { id = "I1", title = "Fix bug", body = "Issue body" } } } })
    local issue_buf = vim.api.nvim_get_current_buf()
    assert.equals("github://a/r/issues/1", vim.api.nvim_buf_get_name(issue_buf))
    assert.equals(
      "Fix bug\nAssignees   —\nLabels      —\nProjects    —\nIssue body",
      table.concat(vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false), "\n")
    )
    vim.cmd("tabclose")

    vim.api.nvim_set_current_win(board_win)
    key("l")
    key("<CR>")
    assert.same({ "open", "https://github.com/a/r/pull/2" }, calls[4].argv)
    respond(4, { code = 0, stdout = "" })

    key("h")
    key("j")
    key("<CR>")
    local draft_win = current_window("gh-projects-preview")
    assert.same({ "Draft issue Draft idea", "draft body" }, list_lines(draft_win))
    assert.equals(4, #pending)
    vim.api.nvim_set_current_win(draft_win)
    key("q")

    vim.api.nvim_set_current_win(board_win)
    key("L")
    key("<CR>")
    assert.same({ "GitHub projects: this item cannot be opened", vim.log.levels.ERROR }, notices[1])
    assert.equals(4, #pending)
    assert.equals(board_win, vim.api.nvim_get_current_win())
  end)

  it("hides archived items and rejects previewing redacted items", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(
      2,
      items_response({
        item_node({
          id = "I1",
          type = "ISSUE",
          option = "todo",
          content = issue_content(1, "Active", empty_connection(), empty_connection()),
        }),
        item_node({
          id = "I2",
          type = "ISSUE",
          option = "done",
          archived = true,
          content = issue_content(2, "Archived", empty_connection(), empty_connection()),
        }),
        item_node({ id = "R1", type = "REDACTED", option = "blocked", option_name = "Blocked", content = vim.NIL }),
      }, 2)
    )
    local win = current_window("gh-projects-board")
    local rendered = list_lines(win)
    assert.equals("alice / Board  ·  2 items  ·  filter: ", rendered[1])
    for _, line in ipairs(rendered) do
      assert.is_nil(line:find("Archived", 1, true))
    end

    key("L")
    assert.same({ column_index = 4, item_id = "R1" }, board.state(vim.api.nvim_win_get_buf(win)).selected)
    key("K")
    assert.same({ "GitHub projects: this item cannot be previewed", vim.log.levels.ERROR }, notices[1])
    assert.is_nil(current_window("gh-projects-preview"))
    assert.equals(2, #pending)
  end)

  it("opens and copies the selected item URL", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win = current_window("gh-projects-board")

    key("<C-o>")
    assert.same({ "open", "https://github.com/a/r/issues/1" }, calls[3].argv)
    respond(3, { code = 0, stdout = "" })

    links_copy.write = function(text)
      copied = text
      return true
    end
    key("ghy")
    assert.equals("https://github.com/a/r/issues/1", copied)
    assert.same({ "Clipboard write requested for 1 URL(s); result unconfirmed", vim.log.levels.INFO }, notices[1])
    assert.equals(win, vim.api.nvim_get_current_win())
  end)

  it("reports that a draft item has no URL", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win = current_window("gh-projects-board")

    key("j")
    assert.same({ column_index = 1, item_id = "I3" }, board.state(vim.api.nvim_win_get_buf(win)).selected)
    key("<C-o>")
    assert.same({ "GitHub projects: this item has no URL", vim.log.levels.ERROR }, notices[1])
    key("ghy")
    assert.same({ "GitHub projects: this item has no URL", vim.log.levels.ERROR }, notices[2])
  end)

  it("refreshes items, keeps the selected item and keeps the previous content on failure", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")

    key("r")
    assert.equals("Loading 4/4...", list_lines(win)[1])
    assert.equals(4, #board.state(buf).items)
    respond(3, items_response({ default_items()[3], default_items()[1], default_items()[2], default_items()[4] }))
    assert.equals("alice / Board  ·  4 items  ·  filter: ", list_lines(win)[1])
    assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
    assert_card_cursor(win, buf, "Fix bug")

    key("r")
    respond(4, items_response({ default_items()[2], default_items()[3], default_items()[4] }))
    assert.same({ column_index = 1, item_id = "I3" }, board.state(buf).selected)
    assert_card_cursor(win, buf, "✎ Draft idea")

    key("r")
    fail(5, 1, "HTTP 403")
    assert.equals("Error: GitHub request failed (exit 1): HTTP 403", list_lines(win)[1])
    assert.equals(3, #board.state(buf).items)
    assert.same({ column_index = 1, item_id = "I3" }, board.state(buf).selected)
  end)

  it("keeps an empty column selected when the no-value column appears or disappears", function()
    local function selected_name(buf)
      local state = board.state(buf)
      return state.columns[state.selected.column_index].name
    end
    local function filter_with(value)
      key("ghs")
      local _, input_buf = current_window("gh-projects-input")
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { value })
      key("<Esc>")
      key("<CR>")
    end
    local cases = {
      { name = "r when it appears", before = default_items, after = items_with_no_value, keys = "ll", reload = "r" },
      {
        name = "r when it disappears",
        before = items_with_no_value,
        after = default_items,
        keys = "lll",
        reload = "r",
      },
      {
        name = "ghs when it appears",
        before = default_items,
        after = items_with_no_value,
        keys = "ll",
        reload = "ghs",
      },
      {
        name = "ghs when it disappears",
        before = items_with_no_value,
        after = default_items,
        keys = "lll",
        reload = "ghs",
      },
    }
    for _, case in ipairs(cases) do
      close_all()
      calls, pending = {}, {}
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(case.before()))
      local _, buf = current_window("gh-projects-board")
      for char in case.keys:gmatch(".") do
        key(char)
      end
      assert.same({ "Done", vim.NIL }, { selected_name(buf), board.state(buf).selected.item_id or vim.NIL }, case.name)

      if case.reload == "r" then
        key("r")
      else
        filter_with("is:open")
      end
      respond(3, items_response(case.after()))
      assert.same({ "Done", vim.NIL }, { selected_name(buf), board.state(buf).selected.item_id or vim.NIL }, case.name)
    end
  end)

  it("hides the no-value column when its last item is removed or gets a group value", function()
    local function column_names(buf)
      return vim.tbl_map(function(column)
        return column.name
      end, board.state(buf).columns)
    end

    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(items_with_no_value()))
    local _, buf = current_window("gh-projects-board")
    board.update_field(
      buf,
      "N1",
      "status",
      { kind = "single_select", value = "done", option_id = "done", name = "Done" }
    )
    assert.same({ "Todo", "In Progress", "Done", "Blocked" }, column_names(buf))
    assert.same({ column_index = 3, item_id = "N1" }, board.state(buf).selected)

    close_all()
    calls, pending = {}, {}
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(items_with_no_value()))
    _, buf = current_window("gh-projects-board")
    board.remove_item(buf, "N1")
    assert.same({ "Todo", "In Progress", "Done", "Blocked" }, column_names(buf))
    assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
  end)

  it("keeps the newest item result when an older response arrives while the board stays open", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")

    key("ghs")
    local _, first_input = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(first_input, 0, -1, false, { "label:bug" })
    key("<Esc>")
    key("<CR>")
    key("ghs")
    local _, second_input = current_window("gh-projects-input")
    vim.api.nvim_buf_set_lines(second_input, 0, -1, false, { "assignee:alice" })
    key("<Esc>")
    key("<CR>")
    assert.equals("Loading 4/4...", list_lines(win)[1])
    assert.equals("label:bug", vim.json.decode(calls[3].opts.stdin).variables.filter)
    assert.equals("assignee:alice", vim.json.decode(calls[4].opts.stdin).variables.filter)

    respond(
      4,
      items_response({
        item_node({
          id = "I9",
          type = "ISSUE",
          option = "todo",
          option_name = "Todo",
          content = issue_content(9, "Newest issue", empty_connection(), empty_connection()),
        }),
      })
    )
    local rendered = list_lines(win)
    assert.equals("alice / Board  ·  1 items  ·  filter: assignee:alice", rendered[1])
    assert.is_not_nil(rendered[2]:find("● Todo 1", 1, true))
    assert.is_not_nil(rendered[2]:find("● In Progress 0", 1, true))
    assert.is_not_nil(table.concat(rendered, "\n"):find("◉ r #9", 1, true))
    assert.same({ column_index = 1, item_id = "I9" }, board.state(buf).selected)
    assert_card_cursor(win, buf, "Newest issue")

    key("?")
    local help_win = current_window("gh-projects-help")
    assert.is_not_nil(help_win)
    local help_lines = list_lines(help_win)

    respond(3, items_response(default_items()))
    assert.equals("alice / Board  ·  1 items  ·  filter: assignee:alice", list_lines(win)[1])
    assert.same(help_lines, list_lines(help_win))
    assert.equals("assignee:alice", board.state(buf).filter)
    assert.equals(1, #board.state(buf).items)
    assert.equals("I9", board.state(buf).items[1].id)
    assert.same({ column_index = 1, item_id = "I9" }, board.state(buf).selected)

    vim.api.nvim_set_current_win(help_win)
    key("q")
    assert.equals(win, current_window("gh-projects-board"))
    assert.equals("alice / Board  ·  1 items  ·  filter: assignee:alice", list_lines(win)[1])
  end)

  it("shows truncation when the item count exceeds max_items", function()
    config.set({ group_by = "Status", column_width = 36, max_items = 2 })
    open_board(1)
    respond(1, detail_response(1, "Board", nil, false, 3))
    respond(2, items_response({ default_items()[1], default_items()[2], default_items()[3] }, 3, true, "cursor"))
    local win, buf = current_window("gh-projects-board")
    assert.equals("Showing 2 of 3", list_lines(win)[1])
    assert.equals(2, #board.state(buf).items)
    assert.equals("Showing 2 of 3", board.state(buf).truncated)
  end)

  it("renders the first page and loads more pages when scrolling to the end", function()
    local first = {
      item_node({
        id = "I1",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(1, "Todo 1", empty_connection(), empty_connection()),
      }),
      item_node({
        id = "I2",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(2, "Todo 2", empty_connection(), empty_connection()),
      }),
    }
    local other_column = {
      item_node({
        id = "I3",
        type = "ISSUE",
        option = "done",
        option_name = "Done",
        content = issue_content(3, "Done 1", empty_connection(), empty_connection()),
      }),
    }
    local last = {
      item_node({
        id = "I4",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(4, "Todo 3", empty_connection(), empty_connection()),
      }),
    }
    open_board(1)
    respond(1, detail_response(1, "Board", nil, false, 4))
    respond(2, items_response(first, 4, true, "c1"))
    local win, buf = current_window("gh-projects-board")
    assert.equals("alice / Board  ·  2/4 items  ·  filter: ", list_lines(win)[1])
    assert.same({ after = "c1", has_next = true, done = false, total = 4 }, board.state(buf).pagination)

    key("j")
    assert.equals("Loading 2/4...", list_lines(win)[1])
    assert.equals(3, #pending)
    assert.same(
      { owner = "alice", number = 1, after = "c1", filter = "" },
      vim.json.decode(calls[3].opts.stdin).variables
    )

    -- This page adds an item to another column only, so the board keeps fetching
    -- until the selected column grows.
    respond(3, items_response(other_column, 4, true, "c2"))
    assert.equals("Loading 3/4...", list_lines(win)[1])
    assert.equals(4, #pending)
    assert.equals("c2", vim.json.decode(calls[4].opts.stdin).variables.after)

    respond(4, items_response(last, 4, false))
    assert.equals("alice / Board  ·  4 items  ·  filter: ", list_lines(win)[1])
    assert.same({ column_index = 1, item_id = "I2" }, board.state(buf).selected)
    assert.same({ 3, 0, 1, 0 }, {
      board.state(buf).columns[1].count,
      board.state(buf).columns[2].count,
      board.state(buf).columns[3].count,
      board.state(buf).columns[4].count,
    })
    assert.is_false(board.state(buf).pagination.has_next)
    assert.is_true(board.state(buf).pagination.done)
    assert.is_nil(board.state(buf).loading)
    assert.is_nil(board.state(buf).error)
  end)

  it("shows the error and keeps the loaded items when a lazy page fails", function()
    local first = {
      item_node({
        id = "I1",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(1, "Todo 1", empty_connection(), empty_connection()),
      }),
    }
    open_board(1)
    respond(1, detail_response(1, "Board", nil, false, 10))
    respond(2, items_response(first, 10, true, "c1"))
    local win, buf = current_window("gh-projects-board")

    key("G")
    fail(3, 1, "HTTP 500")
    assert.equals("Error: GitHub request failed (exit 1): HTTP 500", list_lines(win)[1])
    assert.equals(1, #board.state(buf).items)
    assert.equals("Todo 1", board.selected_item(buf).content.title)
    assert.equals("I1", board.state(buf).selected.item_id)
  end)

  it("shows an empty board and an empty filtered board", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response({}))
    local win, buf = current_window("gh-projects-board")
    assert.equals("alice / Board  ·  0 items  ·  filter: ", list_lines(win)[1])
    assert.equals("No items", list_lines(win)[3])
    assert.same({ column_index = 1, item_id = nil }, board.state(buf).selected)
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("shows help and closes the board with its children", function()
    local parent = vim.api.nvim_get_current_win()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win = current_window("gh-projects-board")

    key("?")
    local help_win = current_window("gh-projects-help")
    assert.is_not_nil(help_win)
    assert.equals(win, current_window("gh-projects-board"))
    local rows = list_lines(help_win)
    local found_ghs, found_ghe = false, false
    for _, row in ipairs(rows) do
      if row:find("ghs", 1, true) then
        found_ghs = true
      end
      if row:find("ghe", 1, true) then
        found_ghe = true
      end
    end
    assert.is_true(found_ghs)
    assert.is_true(found_ghe)
    key("q")
    assert.is_nil(current_window("gh-projects-help"))
    assert.equals(win, vim.api.nvim_get_current_win())

    key("K")
    respond(3, { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Body text" } } } })
    assert.is_not_nil(current_window("gh-projects-preview"))
    vim.api.nvim_set_current_win(win)
    key("q")
    assert.is_nil(current_window("gh-projects-board"))
    assert.is_nil(current_window("gh-projects-preview"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())
  end)

  it("recomputes visible columns and keeps the selection after VimResized", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    key("l")
    key("l")
    assert.same({ column_index = 3, item_id = nil }, board.state(buf).selected)

    vim.o.columns, vim.o.lines = 80, 24
    vim.api.nvim_exec_autocmds("VimResized", {})
    local state = board.state(buf)
    assert.equals(1, state.visible)
    assert.equals(3, state.first_col)
    assert.same({ column_index = 3, item_id = nil }, state.selected)
    assert_header_cursor(win, buf)
    assert.is_not_nil(find_line(win, "● Done 0"))
    assert.is_true(#list_lines(win) >= 19)

    key("l")
    assert.same({ column_index = 4, item_id = "R1" }, board.state(buf).selected)
    assert.equals(4, board.state(buf).first_col)
    assert_card_cursor(win, buf, "[redacted]")
    assert.is_not_nil(find_line(win, "● Blocked 1"))
  end)

  it("renders the board that started the request when the items response arrives in another tab", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    local win, buf = current_window("gh-projects-board")
    local loading = list_lines(win)
    assert.equals("Loading 0/4...", loading[1])
    assert.is_not_nil(loading[2]:find("● Todo 0", 1, true))
    assert.is_not_nil(loading[2]:find("● In Progress 0", 1, true))
    assert.equals("No items", loading[3])

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_win = vim.api.nvim_get_current_win()
    respond(2, items_response(default_items()))

    local rendered = list_lines(win)
    assert.equals("alice / Board  ·  4 items  ·  filter: ", rendered[1])
    assert.is_not_nil(table.concat(rendered, "\n"):find("◉ r #1", 1, true))
    assert.is_not_nil(table.concat(rendered, "\n"):find("⇄ r #2", 1, true))
    assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
    assert_card_cursor(win, buf, "Fix bug")
    assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(other_win, vim.api.nvim_get_current_win())
  end)

  it("recomputes the board layout after VimResized while another tab is current", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    key("l")
    assert.same({ column_index = 2, item_id = "I2" }, board.state(buf).selected)
    assert.equals(2, board.state(buf).visible)

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_win = vim.api.nvim_get_current_win()

    vim.o.columns, vim.o.lines = 80, 24
    vim.api.nvim_exec_autocmds("VimResized", {})

    local state = board.state(buf)
    assert.equals(1, state.visible)
    assert.equals(2, state.first_col)
    assert.same({ column_index = 2, item_id = "I2" }, state.selected)
    assert.is_not_nil(find_line(win, "● In Progress 1"))
    assert.is_true(#list_lines(win) >= 19)
    assert_card_cursor(win, buf, "Add feature")
    assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(other_win, vim.api.nvim_get_current_win())
  end)

  it("updates fields, adds and removes items, and selects items", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")
    local state = board.state(buf)

    board.update_field(buf, "I1", "status", {
      kind = "single_select",
      value = "doing",
      option_id = "doing",
      name = "In Progress",
    })
    assert.equals(1, state.columns[1].count)
    assert.equals(2, state.columns[2].count)
    assert.same({ column_index = 2, item_id = "I1" }, state.selected)
    assert.equals("I1", board.selected_item(buf).id)
    assert_card_cursor(win, buf, "Fix bug")

    board.update_field(buf, "I1", "notes", { kind = "text", value = "note" })
    assert.same({ column_index = 2, item_id = "I1" }, state.selected)
    assert.equals("note", board.selected_item(buf).values.notes.value)

    board.add_item(buf, {
      id = "I5",
      type = "PULL_REQUEST",
      content = {
        number = 5,
        title = "New PR",
        url = "https://github.com/a/r/pull/5",
        repository = "a/r",
        labels = { total_count = 0, nodes = {} },
        assignees = { total_count = 0, nodes = {} },
      },
      values = {
        status = { kind = "single_select", value = "done", option_id = "done", name = "Done" },
      },
      archived = false,
    })
    assert.same({ column_index = 3, item_id = "I5" }, state.selected)
    assert.equals(1, state.columns[3].count)

    board.remove_item(buf, "I5")
    assert.same({ column_index = 3, item_id = nil }, state.selected)
    assert.equals(0, state.columns[3].count)

    board.select_item(buf, "I3")
    assert.same({ column_index = 1, item_id = "I3" }, state.selected)
    assert_card_cursor(win, buf, "✎ Draft idea")
  end)

  describe("moving items", function()
    local MOVE_DONE = { "GitHub projects: move done", vim.log.levels.INFO }
    local MOVE_BLOCKED = { "GitHub projects: finish the move with <CR> or cancel it with q", vim.log.levels.ERROR }

    local function column_ids(buf, index)
      local ids = {}
      for _, item in ipairs(board.state(buf).columns[index].items) do
        ids[#ids + 1] = item.id
      end
      return ids
    end

    local function variables(index)
      return vim.json.decode(calls[index].opts.stdin).variables
    end

    local function field_updated(id)
      return { data = { updateProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
    end

    local function field_cleared(id)
      return { data = { clearProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
    end

    local function position_updated()
      return { data = { updateProjectV2ItemPosition = { clientMutationId = vim.NIL } } }
    end

    local function open_default_board()
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(default_items()))
      return current_window("gh-projects-board")
    end

    it("maps ghm on the board instead of <C-h> and <C-l>", function()
      local _, buf = open_default_board()
      assert_mapping(buf, "n", "ghm")
      assert.is_nil(mapping(buf, "n", "<C-H>"))
      assert.is_nil(mapping(buf, "n", "<C-L>"))
    end)

    it("starts the move mode with ghm without moving the item and shows it in the header", function()
      local win, buf = open_default_board()
      key("ghm")
      assert.same({ "I1", "I3" }, column_ids(buf, 1))
      assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
      assert.equals(
        "alice / Board  ·  4 items  ·  filter:   ·  moving: h/l column, j/k order, <CR> save, q cancel",
        list_lines(win)[1]
      )
      key("q")
      assert.equals("alice / Board  ·  4 items  ·  filter: ", list_lines(win)[1])
      assert.equals(win, current_window("gh-projects-board"))
    end)

    it("moves an item to the next column with l in the move mode and saves only the group field on <CR>", function()
      local win, buf = open_default_board()

      key("ghm")
      key("l")
      assert.same({ "I3" }, column_ids(buf, 1))
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      assert.same({ column_index = 2, item_id = "I1" }, board.state(buf).selected)
      assert_card_cursor(win, buf, "Fix bug")
      assert.equals(2, #calls)

      key("<CR>")
      assert.equals(3, #calls)
      assert.same(
        { projectId = "P1", itemId = "I1", fieldId = "status", value = { singleSelectOptionId = "doing" } },
        variables(3)
      )
      respond(3, field_updated("I1"))
      assert.equals(3, #calls)
      assert.same({ MOVE_DONE }, notices)
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      assert.equals("doing", board.selected_item(buf).values.status.option_id)
      assert.equals(1, #vim.api.nvim_list_tabpages())

      key("<CR>")
      assert.equals(2, #vim.api.nvim_list_tabpages())
    end)

    it("clears the group field when an item is moved to the no-value column", function()
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(items_with_no_value()))
      local _, buf = current_window("gh-projects-board")
      key("l")
      key("ghm")
      key("h")
      assert.same({ "I1", "N1" }, column_ids(buf, 1))

      key("<CR>")
      assert.same({ projectId = "P1", itemId = "I1", fieldId = "status" }, variables(3))
      assert.is_truthy(vim.json.decode(calls[3].opts.stdin).query:find("clearProjectV2ItemFieldValue", 1, true))
      respond(3, field_cleared("I1"))
      assert.same({ MOVE_DONE }, notices)
      assert.equals(3, #calls)
    end)

    it("hides the no-value column when its last item is moved out and cannot move back into it", function()
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(items_with_no_value()))
      local _, buf = current_window("gh-projects-board")
      key("ghm")
      key("l")
      assert.same(
        { "Todo", "In Progress", "Done", "Blocked" },
        vim.tbl_map(function(column)
          return column.name
        end, board.state(buf).columns)
      )
      assert.same({ "I1", "I3", "N1" }, column_ids(buf, 1))
      assert.same({ column_index = 1, item_id = "N1" }, board.state(buf).selected)

      key("h")
      assert.same({ column_index = 1, item_id = "N1" }, board.state(buf).selected)
      assert.equals("Todo", board.state(buf).columns[1].name)

      key("<CR>")
      assert.same(
        { projectId = "P1", itemId = "N1", fieldId = "status", value = { singleSelectOptionId = "todo" } },
        variables(3)
      )
      respond(3, field_updated("N1"))
      assert.same({ MOVE_DONE }, notices)
      assert.same(
        { "Todo", "In Progress", "Done", "Blocked" },
        vim.tbl_map(function(column)
          return column.name
        end, board.state(buf).columns)
      )
    end)

    it("shows the no-value column again when moving its last item out is cancelled", function()
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(items_with_no_value()))
      local _, buf = current_window("gh-projects-board")
      key("ghm")
      key("l")
      assert.equals("Todo", board.state(buf).columns[1].name)

      key("q")
      assert.same(
        { "No Status", "Todo", "In Progress", "Done", "Blocked" },
        vim.tbl_map(function(column)
          return column.name
        end, board.state(buf).columns)
      )
      assert.same({ column_index = 1, item_id = "N1" }, board.state(buf).selected)
      assert.equals(2, #calls)
    end)

    it("reorders an item within its column with j and k and saves the position on <CR>", function()
      local win, buf = open_default_board()

      key("ghm")
      assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
      key("j")
      assert.same({ "I3", "I1" }, column_ids(buf, 1))
      assert_card_cursor(win, buf, "Fix bug")
      key("j")
      assert.same({ "I3", "I1" }, column_ids(buf, 1))

      key("<CR>")
      assert.equals(3, #calls)
      assert.same({ projectId = "P1", itemId = "I1", afterId = "I3" }, variables(3))
      respond(3, position_updated())
      assert.same({ MOVE_DONE }, notices)
      assert.same({ "I3", "I1" }, column_ids(buf, 1))
    end)

    for _, case in ipairs({
      { name = "h on the first column", keys = { "ghm", "h" }, column = 1, ids = { "I1", "I3" } },
      { name = "l on the last column", keys = { "L", "ghm", "l" }, column = 4, ids = { "R1" } },
      { name = "k at the top of the column", keys = { "ghm", "k" }, column = 1, ids = { "I1", "I3" } },
    }) do
      it("does not move the item with " .. case.name .. " in the move mode", function()
        local _, buf = open_default_board()
        vim.v.errmsg = ""
        for _, value in ipairs(case.keys) do
          key(value)
        end
        assert.equals("", vim.v.errmsg)
        local selected = board.state(buf).selected
        assert.same(case.ids, column_ids(buf, case.column))
        assert.same({ column_index = case.column, item_id = case.ids[1] }, selected)
        assert.is_not_nil(board.state(buf).moving)
        assert.same({}, notices)
      end)
    end

    it("moves an item to the top of its column without a previous item", function()
      local _, buf = open_default_board()
      key("j")
      key("ghm")
      key("k")
      assert.same({ "I3", "I1" }, column_ids(buf, 1))

      key("<CR>")
      assert.same({ projectId = "P1", itemId = "I3" }, variables(3))
      respond(3, position_updated())
      assert.same({ MOVE_DONE }, notices)
    end)

    it("saves the group field and then the position when both changed", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      key("j")
      assert.same({ "I2", "I1" }, column_ids(buf, 2))

      key("<CR>")
      assert.same(
        { projectId = "P1", itemId = "I1", fieldId = "status", value = { singleSelectOptionId = "doing" } },
        variables(3)
      )
      assert.equals(3, #calls)
      respond(3, field_updated("I1"))
      assert.same({ projectId = "P1", itemId = "I1", afterId = "I2" }, variables(4))
      assert.same({}, notices)
      respond(4, position_updated())
      assert.same({ MOVE_DONE }, notices)
      assert.same({ "I2", "I1" }, column_ids(buf, 2))
    end)

    for _, case in ipairs({
      { name = "a column round trip", keys = { "ghm", "l", "h" } },
      { name = "j then k", keys = { "ghm", "j", "k" } },
      { name = "k then j", keys = { "j", "ghm", "k", "j" } },
      { name = "j then k in another column and back", keys = { "ghm", "l", "j", "k", "h" } },
    }) do
      it("does not send anything when " .. case.name .. " leaves the column and order unchanged", function()
        local _, buf = open_default_board()
        for _, value in ipairs(case.keys) do
          key(value)
        end
        assert.same({ "I1", "I3" }, column_ids(buf, 1))
        assert.same({ "I2" }, column_ids(buf, 2))
        key("<CR>")
        assert.equals(2, #calls)
        assert.same({}, notices)
        assert.is_nil(board.state(buf).moving)
        assert.equals(1, #vim.api.nvim_list_tabpages())
      end)
    end

    it("moves an item to the top of another column without a previous item", function()
      local _, buf = open_default_board()
      key("j")
      key("ghm")
      key("l")
      assert.same({ "I2", "I3" }, column_ids(buf, 2))
      key("k")
      assert.same({ "I3", "I2" }, column_ids(buf, 2))

      key("<CR>")
      respond(3, field_updated("I3"))
      assert.same({ projectId = "P1", itemId = "I3" }, variables(4))
      respond(4, position_updated())
      assert.same({ MOVE_DONE }, notices)
    end)

    local function draft(id, option)
      return item_node({ id = id, type = "DRAFT_ISSUE", option = option, content = draft_content("Draft " .. id, "") })
    end

    local function item_ids(buf)
      local ids = {}
      for _, item in ipairs(board.state(buf).items) do
        ids[#ids + 1] = item.id
      end
      return ids
    end

    local function open_board_with(nodes)
      open_board(1)
      respond(1, detail_response(1, "Board"))
      respond(2, items_response(nodes))
      return current_window("gh-projects-board")
    end

    it("moves by the count given before h, l, j and k in the move mode", function()
      local _, buf = open_board_with({
        draft("A", "todo"),
        draft("B", "todo"),
        draft("C", "todo"),
        draft("D", "todo"),
        draft("E", "done"),
      })
      key("ghm")
      key("2l")
      assert.same({ "A", "E" }, column_ids(buf, 3))
      key("2h")
      assert.same({ "A", "B", "C", "D" }, column_ids(buf, 1))
      key("2j")
      assert.same({ "B", "C", "A", "D" }, column_ids(buf, 1))
      key("2k")
      assert.same({ "A", "B", "C", "D" }, column_ids(buf, 1))
      key("2l")
      assert.same({ "A", "E" }, column_ids(buf, 3))
      key("q")

      key("2l")
      key("ghm")
      key("2h")
      assert.same({ "A", "B", "C", "D", "E" }, column_ids(buf, 1))
    end)

    it("keeps the local order equal to GitHub when the move sends no position", function()
      local _, buf = open_default_board()
      key("ghm")
      key("j")
      key("k")
      key("<CR>")
      assert.equals(2, #calls)
      assert.same({ "I1", "I2", "I3", "R1" }, item_ids(buf))

      key("ghm")
      key("l")
      key("<CR>")
      respond(3, field_updated("I1"))
      assert.equals(3, #calls)
      assert.same({ MOVE_DONE }, notices)
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      assert.same({ "I1", "I2", "I3", "R1" }, item_ids(buf))
    end)

    it("keeps the original local order when only the column is saved after j and k", function()
      local _, buf = open_board_with({ draft("A", "todo"), draft("B", "todo"), draft("X", "doing") })
      key("ghm")
      key("l")
      key("j")
      key("k")
      assert.same({ "A", "X" }, column_ids(buf, 2))
      key("<CR>")
      respond(3, field_updated("A"))
      assert.equals(3, #calls)
      assert.same({ MOVE_DONE }, notices)
      assert.same({ "A", "B", "X" }, item_ids(buf))
    end)

    it("places the item after the sent previous item in the local order", function()
      local _, buf = open_board_with({
        draft("A", "todo"),
        draft("X", "doing"),
        draft("B", "todo"),
        draft("C", "todo"),
      })
      key("G")
      key("ghm")
      key("k")
      assert.same({ "A", "C", "B" }, column_ids(buf, 1))
      key("<CR>")
      assert.same({ projectId = "P1", itemId = "C", afterId = "A" }, variables(3))
      respond(3, position_updated())
      assert.same({ "A", "C", "X", "B" }, item_ids(buf))

      key("l")
      key("ghm")
      key("h")
      key("<CR>")
      respond(4, field_updated("X"))
      assert.same({ "A", "C", "X", "B" }, column_ids(buf, 1))
    end)

    it("places an item moved to the top of a column at the top of the local order", function()
      local _, buf = open_default_board()
      key("j")
      key("ghm")
      key("l")
      key("k")
      key("<CR>")
      respond(3, field_updated("I3"))
      respond(4, position_updated())
      assert.same({ "I3", "I1", "I2", "R1" }, item_ids(buf))
    end)

    it("does not start a move while the items are being reloaded", function()
      local _, buf = open_default_board()
      key("r")
      key("ghm")
      assert.same({ { "GitHub projects: wait for the items to load before moving", vim.log.levels.ERROR } }, notices)
      assert.is_nil(board.state(buf).moving)
      assert.same({ "I1", "I3" }, column_ids(buf, 1))

      respond(3, items_response(default_items()))
      key("ghm")
      key("l")
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
    end)

    it("keeps the move when the same board is opened again during the move", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      open_board(1)
      assert.equals(2, #calls)
      assert.same({ MOVE_BLOCKED }, notices)
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      assert.is_not_nil(board.state(buf).moving)
    end)

    it("cancels the move with q or <Esc> and restores the column and order", function()
      local win, buf = open_default_board()
      for _, cancel in ipairs({ "q", "<Esc>" }) do
        key("ghm")
        key("l")
        key("j")
        assert.same({ "I2", "I1" }, column_ids(buf, 2))

        key(cancel)
        assert.same({ "I1", "I3" }, column_ids(buf, 1))
        assert.same({ "I2" }, column_ids(buf, 2))
        assert.same({ column_index = 1, item_id = "I1" }, board.state(buf).selected)
        assert.equals(win, current_window("gh-projects-board"))
        assert.equals(2, #calls)
      end
      key("q")
      assert.is_nil(current_window("gh-projects-board"))
    end)

    it("keeps the move pending on failure and does not resend a saved group field", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      key("j")
      key("<CR>")
      respond(3, field_updated("I1"))
      fail(4, 1, "position failed")
      local failure = "GitHub projects: GitHub request failed (exit 1): position failed"
      assert.same({ { failure, vim.log.levels.ERROR } }, notices)
      assert.same({ "I2", "I1" }, column_ids(buf, 2))

      key("<CR>")
      assert.equals(5, #calls)
      assert.same({ projectId = "P1", itemId = "I1", afterId = "I2" }, variables(5))
      respond(5, position_updated())
      assert.same(MOVE_DONE, notices[2])
    end)

    it("restores the saved column when a partially saved move is cancelled", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      key("j")
      key("<CR>")
      respond(3, field_updated("I1"))
      fail(4, 1, "position failed")

      key("q")
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      assert.same({ "I3" }, column_ids(buf, 1))
      assert.equals("doing", board.selected_item(buf).values.status.option_id)
    end)

    it("ignores keys while the move is being saved", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      key("<CR>")
      key("<CR>")
      key("q")
      key("l")
      assert.equals(3, #calls)
      assert.same({ "I1", "I2" }, column_ids(buf, 2))
      respond(3, field_updated("I1"))
      assert.same({ MOVE_DONE }, notices)
    end)

    it("rejects other board operations during a move", function()
      local _, buf = open_default_board()
      key("ghm")
      key("l")
      for _, other in ipairs({ "r", "H", "K", "ghe" }) do
        key(other)
      end
      assert.equals(2, #calls)
      assert.same({ MOVE_BLOCKED, MOVE_BLOCKED, MOVE_BLOCKED, MOVE_BLOCKED }, notices)
      assert.same({ column_index = 2, item_id = "I1" }, board.state(buf).selected)
      assert.equals(1, #float_windows())
    end)

    it("asks to select an item when the selected column is empty", function()
      local _, buf = open_default_board()
      key("l")
      key("l")
      key("ghm")
      assert.same({ { "GitHub projects: select an item to move", vim.log.levels.ERROR } }, notices)
      key("q")
      assert.is_nil(current_window("gh-projects-board"))
      assert.is_nil(board.state(buf))
    end)
  end)

  it("reuses an open board and refetches it", function()
    open_board(1)
    respond(1, detail_response(1, "Board"))
    respond(2, items_response(default_items()))
    local win, buf = current_window("gh-projects-board")

    open_board(1)
    assert.same({ win, buf }, { current_window("gh-projects-board") })
    assert.equals(1, #float_windows())
    assert.equals("Loading 4/4...", list_lines(win)[1])
    assert.equals(3, #pending)
    respond(3, items_response(default_items()))
    assert.equals("alice / Board  ·  4 items  ·  filter: ", list_lines(win)[1])
  end)

  it("does not open a board for a missing or closed project and ignores late responses", function()
    local parent = vim.api.nvim_get_current_win()
    open_board(5)
    respond(1, { data = { user = { projectV2 = vim.NIL } } })
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.same({ "GitHub projects: project not found", vim.log.levels.ERROR }, notices[1])

    open_board(6)
    local closed = detail_response(6, "Closed")
    closed.data.user.projectV2.closed = true
    respond(3, closed)
    assert.is_nil(current_window("gh-projects-board"))
    assert.same({ "GitHub projects: Project #6 is closed", vim.log.levels.ERROR }, notices[2])

    open_board(7)
    respond(5, detail_response(7, "Late"))
    local win = current_window("gh-projects-board")
    assert.is_not_nil(win)
    key("q")
    assert.is_nil(current_window("gh-projects-board"))
    respond(6, items_response(default_items()))
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(parent, vim.api.nvim_get_current_win())

    open_board(8)
    fail(7, 1, "HTTP 500")
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.same({ "GitHub projects: GitHub request failed (exit 1): HTTP 500", vim.log.levels.ERROR }, notices[3])
  end)

  it("does not open the board when the project detail resolves in another tab", function()
    local parent = vim.api.nvim_get_current_win()
    open_board(1)
    vim.cmd("tabnew")
    local other = vim.api.nvim_get_current_win()
    respond(1, detail_response(1, "Board"))
    assert.equals(0, #float_windows())
    assert.equals(2, #pending)
    assert.equals(other, vim.api.nvim_get_current_win())

    vim.cmd("tabnext 1")
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())
  end)

  it("does not open the board when the parent window was closed before the detail resolves", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(parent)
    open_board(1)
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_close(parent, true)
    respond(1, detail_response(1, "Board"))
    assert.equals(0, #float_windows())
    assert.equals(2, #pending)
    assert.equals(other, vim.api.nvim_get_current_win())
  end)
end)
