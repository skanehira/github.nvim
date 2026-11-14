local process = require("github.core.process")
local config = require("github.core.config")
local board = require("github.features.projects.board")
local item_manage = require("github.features.projects.item_manage")
local float = require("github.core.float")

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

local function find_float(predicate)
  for _, win in ipairs(float_windows()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if predicate(win, buf) then
      return win, buf
    end
  end
end

local function buffer_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function select_window()
  return find_float(function(_, buf)
    local lines = buffer_lines(buf)
    return #lines == 2 and lines[1] == "既存のIssue/PR" and lines[2] == "下書きIssue"
  end)
end

local function input_window()
  return find_float(function(_, buf)
    return vim.bo[buf].filetype == "gh-projects-input"
  end)
end

local function body_window()
  return find_float(function(_, buf)
    return vim.bo[buf].filetype == "markdown"
  end)
end

local function confirm_window()
  return find_float(function(_, buf)
    local lines = buffer_lines(buf)
    return #lines == 3 and lines[1] == "Delete this item from the project?"
  end)
end

local function board_window()
  return find_float(function(_, buf)
    return vim.bo[buf].filetype == "gh-projects-board"
  end)
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

local function detail_response(number, title, filter, item_count)
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
          views = {
            nodes = {
              { number = 1, name = "Board", layout = "BOARD_LAYOUT", filter = filter or "" },
            },
          },
        },
      },
    },
  }
end

local function issue_content(number, title, labels, assignees)
  return {
    __typename = "Issue",
    number = number,
    title = title,
    state = "OPEN",
    url = "https://github.com/a/r/issues/" .. number,
    repository = { nameWithOwner = "a/r" },
    labels = labels or { totalCount = 0, nodes = {} },
    assignees = assignees or { totalCount = 0, nodes = {} },
    subIssuesSummary = vim.NIL,
    closedByPullRequestsReferences = vim.NIL,
  }
end

local function pr_content(number, title, labels)
  return {
    __typename = "PullRequest",
    number = number,
    title = title,
    state = "OPEN",
    url = "https://github.com/a/r/pull/" .. number,
    repository = { nameWithOwner = "a/r" },
    labels = labels or { totalCount = 0, nodes = {} },
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
    fieldValues = opts.no_values and vim.NIL or { nodes = values },
  }
end

local function items_response(nodes, total_count)
  return {
    data = {
      user = {
        projectV2 = {
          items = {
            totalCount = total_count or #nodes,
            pageInfo = { hasNextPage = false, endCursor = vim.NIL },
            nodes = nodes,
          },
        },
      },
    },
  }
end

local function default_items()
  return {
    item_node({
      id = "I1",
      type = "ISSUE",
      option = "todo",
      option_name = "Todo",
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
    item_node({ id = "R1", type = "REDACTED", content = vim.NIL }),
  }
end

local function resolve_response(typename, id)
  return {
    data = {
      repository = {
        issueOrPullRequest = { __typename = typename, id = id },
      },
    },
  }
end

local function added_item_response(item)
  return {
    data = {
      addProjectV2ItemById = { item = item },
    },
  }
end

local function draft_item_response(item)
  return {
    data = {
      addProjectV2DraftIssue = { projectItem = item },
    },
  }
end

local function delete_response(item_id)
  return {
    data = {
      deleteProjectV2Item = { deletedItemId = item_id },
    },
  }
end

local ADD_SUCCESS =
  "GitHub projects: added the item to the project; it may already have been in the project. Run r to refresh"
local ADD_DRAFT_SUCCESS = "GitHub projects: added the draft issue to the project"
local ADD_DUPLICATE = "GitHub projects: the item is already in the project; selected the existing item"
local ADD_FILTER_MISMATCH = "GitHub projects: added the item to the project, "
  .. "but it does not match the current filter; clear the filter with ghs to see it"
local ADD_DRAFT_FILTER_MISMATCH = "GitHub projects: added the draft issue to the project, "
  .. "but it does not match the current filter; clear the filter with ghs to see it"
local ADD_FILTER_UNKNOWN = "GitHub projects: added the item to the project; "
  .. "could not determine whether it matches the current filter; clear the filter with ghs to see it"
local ADD_GROUP_MISSING = "GitHub projects: added the item to the project; the group value is missing. Run r to refresh"
local DELETE_SUCCESS = "GitHub projects: removed the item from the project; the Issue/PR was not deleted"
local EMPTY_REFERENCE = "GitHub projects: enter an Issue/PR URL or owner/repo#number"
local INVALID_REFERENCE = "GitHub projects: invalid Issue/PR reference; "
  .. "use https://github.com/<owner>/<repo>/issues/<number>, "
  .. "https://github.com/<owner>/<repo>/pull/<number> or <owner>/<repo>#<number>"
local INVALID_OWNER = "GitHub projects: invalid owner or repository"
local INVALID_NUMBER = "GitHub projects: invalid Issue/PR number"

local function open_board(number)
  board.open({
    owner = { host = "github.com", owner = "alice", type = "User" },
    number = number,
    parent_win = vim.api.nvim_get_current_win(),
  })
end

local function prepare_board(filter, item_count)
  open_board(1)
  respond(1, detail_response(1, "Board", filter, item_count))
  -- The board requests the detail and an unfiltered first page in parallel. A
  -- filtered view discards that page and requests the filtered page afterwards.
  respond(2, items_response(default_items(), item_count))
  if filter and filter ~= "" then
    respond(3, items_response(default_items(), item_count))
  end
  local win, buf = board_window()
  return win, buf
end

describe("projects item manage", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    fake_gh()
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    restore_gh()
    close_all()
    vim.o.columns, vim.o.lines = columns, lines
    config.set({ group_by = "Status", column_width = 36, max_items = 1000 })
  end)

  it("opens the add choice with the expected size and reuses the flow", function()
    local board_buf = select(2, prepare_board())
    item_manage.open_add(board_buf)
    local win, buf = select_window()
    assert.is_not_nil(win)
    assert.same({ 47, 4 }, { vim.api.nvim_win_get_config(win).width, vim.api.nvim_win_get_config(win).height })
    assert.same({ "既存のIssue/PR", "下書きIssue" }, buffer_lines(buf))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert_mapping(buf, "n", "j")
    assert_mapping(buf, "n", "k")
    assert_mapping(buf, "n", "<CR>")
    assert_mapping(buf, "n", "q")
    assert_mapping(buf, "n", "<Esc>")

    item_manage.open_add(board_buf)
    assert.equals(win, select_window())
    assert.equals(2, #float_windows())
  end)

  it("adds an existing issue to the matching column and selects it", function()
    local board_win, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local input_win, input_buf = input_window()
    assert.is_not_nil(input_win)
    assert.same(
      { 59, 1 },
      { vim.api.nvim_win_get_config(input_win).width, vim.api.nvim_win_get_config(input_win).height }
    )
    assert.same({ { "Issue/PR URL or owner/repo#number", "FloatTitle" } }, vim.api.nvim_win_get_config(input_win).title)
    assert.equals("gh-projects-input", vim.bo[input_buf].filetype)
    assert.is_true(vim.bo[input_buf].modifiable)
    assert_mapping(input_buf, "n", "<CR>")
    assert_mapping(input_buf, "n", "<C-C>")
    assert_mapping(input_buf, "n", "q")
    assert_mapping(input_buf, "i", "<CR>")
    assert_mapping(input_buf, "i", "<C-C>")

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "  a/r#5  " })
    key("<CR>")
    assert.equals(3, #pending)
    assert.equals(3, #float_windows())
    assert.is_true(vim.fn.stridx(calls[3].opts.stdin, "issueOrPullRequest") > 0)
    assert.same({ owner = "a", repo = "r", number = 5 }, vim.json.decode(calls[3].opts.stdin).variables)
    respond(3, resolve_response("Issue", "NODE5"))

    assert.equals(4, #pending)
    assert.is_true(vim.fn.stridx(calls[4].opts.stdin, "addProjectV2ItemById") > 0)
    assert.same({ projectId = "P1", contentId = "NODE5" }, vim.json.decode(calls[4].opts.stdin).variables)
    respond(
      4,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "New issue"),
      }))
    )

    local state = board.state(board_buf)
    assert.equals(5, #state.items)
    assert.equals("I5", state.items[5].id)
    assert.same({ column_index = 1, item_id = "I5" }, state.selected)
    assert.equals(3, state.columns[1].count)
    assert.equals(5, state.project.item_count)
    assert.equals(ADD_SUCCESS, notices[1][1])
    assert.equals(vim.log.levels.INFO, notices[1][2])
    assert.is_nil(select_window())
    assert.is_nil(input_window())
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.equals(board_buf, vim.api.nvim_win_get_buf(board_win))
  end)

  it("rejects invalid references without sending a request and keeps the input", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    local cases = {
      { "   ", EMPTY_REFERENCE },
      { "https://github.com/a/r/issues/5/extra", INVALID_REFERENCE },
      { "https://github.com/a/r/issues/5?x=1", INVALID_REFERENCE },
      { "https://github.com/a/r/issues/5#note", INVALID_REFERENCE },
      { "https://github.com/a/r/commits/5", INVALID_REFERENCE },
      { "a/r", INVALID_REFERENCE },
      { "a_r/r#1", INVALID_OWNER },
      { "a/r!#1", INVALID_OWNER },
      { "a/r#0", INVALID_NUMBER },
      { "a/r#-1", INVALID_NUMBER },
      { "a/r#1.5", INVALID_NUMBER },
      { "a/r#9007199254740992", INVALID_NUMBER },
    }
    for index, case in ipairs(cases) do
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { case[1] })
      key("<CR>")
      assert.equals(2, #pending)
      assert.same({ case[2], vim.log.levels.ERROR }, notices[#notices])
      assert.is_true(float.is_open("projects-add:existing:" .. board_buf))
      assert.same({ case[1] }, buffer_lines(input_buf))
      assert.equals(index, #notices)
    end
  end)

  it("accepts trailing slashes and pull request URLs and trims the input", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "  https://github.com/a/r/pull/7/  " })
    key("<CR>")
    assert.same({ owner = "a", repo = "r", number = 7 }, vim.json.decode(calls[3].opts.stdin).variables)
    respond(3, resolve_response("PullRequest", "NODE7"))
    respond(
      4,
      added_item_response(item_node({
        id = "I7",
        type = "PULL_REQUEST",
        option = "doing",
        option_name = "In Progress",
        content = pr_content(7, "New pull request"),
      }))
    )
    local state = board.state(board_buf)
    assert.same({ column_index = 2, item_id = "I7" }, state.selected)
    assert.equals(2, state.columns[2].count)
    assert.equals(5, state.project.item_count)
    assert.is_nil(select_window())
    assert.is_nil(input_window())
  end)

  it("accepts repositories whose names start with a dot", function()
    local cases = {
      { input = "alice/.github#14", repo = ".github" },
      { input = "https://github.com/alice/.github/issues/14", repo = ".github" },
    }
    for index, case in ipairs(cases) do
      close_all()
      calls, pending, notices = {}, {}, {}
      local _, board_buf = prepare_board()
      item_manage.open_add(board_buf)
      key("<CR>")
      local _, input_buf = input_window()
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { case.input })
      key("<CR>")
      assert.same({ owner = "alice", repo = case.repo, number = 14 }, vim.json.decode(calls[3].opts.stdin).variables)
      respond(3, resolve_response("Issue", "NODE" .. index))
      respond(
        4,
        added_item_response(item_node({
          id = "D" .. index,
          type = "ISSUE",
          option = "todo",
          option_name = "Todo",
          content = issue_content(14, "Dot repository issue"),
        }))
      )
      local state = board.state(board_buf)
      assert.equals(5, #state.items)
      assert.same({ column_index = 1, item_id = "D" .. index }, state.selected)
      assert.same({ ADD_SUCCESS, vim.log.levels.INFO }, notices[1])
    end
  end)

  it("keeps the input when the issue or pull request cannot be resolved", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#99" })
    key("<CR>")
    respond(3, { data = { repository = { issueOrPullRequest = vim.NIL } } })
    assert.same({ "GitHub projects: issue or pull request not found", vim.log.levels.ERROR }, notices[1])
    assert.equals(3, #pending)
    assert.same({ "a/r#99" }, buffer_lines(input_buf))
    assert.is_true(float.is_open("projects-add:existing:" .. board_buf))
  end)

  it("keeps the input when the resolve request needs authentication", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#1" })
    key("<CR>")
    fail(3, 4, "gh auth login")
    assert.same({
      "GitHub projects: gh is not authenticated; run gh auth login --hostname github.com",
      vim.log.levels.ERROR,
    }, notices[1])
    assert.same({ "a/r#1" }, buffer_lines(input_buf))
    assert.is_true(float.is_open("projects-add:existing:" .. board_buf))
  end)

  it("reports a temporary conflict and accepts a retry", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(3, resolve_response("Issue", "NODE5"))
    respond(4, { errors = { "A temporary conflict occurred" } })
    assert.equals("GitHub projects: A temporary conflict occurred", notices[1][1])
    assert.same({ "a/r#5" }, buffer_lines(input_buf))
    assert.is_true(float.is_open("projects-add:existing:" .. board_buf))

    key("<CR>")
    assert.equals(5, #pending)
    respond(5, resolve_response("Issue", "NODE5"))
    assert.equals(6, #pending)
    respond(
      6,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Retried issue"),
      }))
    )
    assert.equals("I5", board.selected_item(board_buf).id)
    assert.is_nil(input_window())
  end)

  it("does not claim success when an add fails without a known result", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(3, resolve_response("Issue", "NODE5"))
    fail(4, 1, "")
    assert.same({
      "GitHub projects: GitHub request failed (exit 1); run r to refresh",
      vim.log.levels.ERROR,
    }, notices[1])
    assert.equals(4, #board.state(board_buf).items)
    assert.same({ "a/r#5" }, buffer_lines(input_buf))
    assert.is_true(float.is_open("projects-add:existing:" .. board_buf))
  end)

  it("ignores repeated submits while a request is in flight", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    key("<CR>")
    assert.equals(3, #pending)
    respond(3, resolve_response("Issue", "NODE5"))
    key("<CR>")
    key("<CR>")
    assert.equals(4, #pending)
    respond(
      4,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "New issue"),
      }))
    )
    assert.equals(5, #board.state(board_buf).items)
  end)

  it("adds a draft issue with its title and body and caches the body", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local title_win, title_buf = input_window()
    assert.same({ { "Draft title", "FloatTitle" } }, vim.api.nvim_win_get_config(title_win).title)
    assert.equals("gh-projects-input", vim.bo[title_buf].filetype)
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "  My draft  " })
    key("<CR>")

    local body_win, body_buf = body_window()
    assert.is_not_nil(body_win)
    assert.same(
      { 82, 22 },
      { vim.api.nvim_win_get_config(body_win).width, vim.api.nvim_win_get_config(body_win).height }
    )
    assert.same(
      { { "Draft body (C-s to add, q/Esc to cancel)", "FloatTitle" } },
      vim.api.nvim_win_get_config(body_win).title
    )
    assert.equals("markdown", vim.bo[body_buf].filetype)
    assert.is_true(vim.bo[body_buf].modifiable)
    assert.is_false(vim.bo[body_buf].readonly)
    assert_mapping(body_buf, "n", "<C-S>")
    assert_mapping(body_buf, "n", "q")
    assert_mapping(body_buf, "n", "<Esc>")
    assert_mapping(body_buf, "i", "<C-S>")
    assert.is_true(float.is_open("projects-add:title:" .. board_buf))

    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "line1", "line2" })
    key("<C-s>")
    assert.equals(3, #pending)
    assert.same(
      { projectId = "P1", title = "My draft", body = "line1\nline2" },
      vim.json.decode(calls[3].opts.stdin).variables
    )
    respond(
      3,
      draft_item_response(item_node({
        id = "D1",
        type = "DRAFT_ISSUE",
        content = draft_content("My draft", "line1\nline2"),
      }))
    )

    local state = board.state(board_buf)
    assert.equals(5, #state.items)
    assert.same({ column_index = 4, item_id = "D1" }, state.selected)
    assert.equals(2, state.columns[4].count)
    assert.equals("line1\nline2", state.body_cache.D1)
    assert.equals(5, state.project.item_count)
    assert.same({ ADD_DRAFT_SUCCESS, vim.log.levels.INFO }, notices[1])
    assert.is_nil(select_window())
    assert.is_nil(input_window())
    assert.is_nil(body_window())
  end)

  it("adds a draft issue with an empty body", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local _, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "Empty body" })
    key("<CR>")
    local _, body_buf = body_window()
    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "" })
    key("<C-s>")
    assert.same({ projectId = "P1", title = "Empty body", body = "" }, vim.json.decode(calls[3].opts.stdin).variables)
    respond(
      3,
      draft_item_response(item_node({
        id = "D2",
        type = "DRAFT_ISSUE",
        content = draft_content("Empty body", ""),
      }))
    )
    assert.equals("", board.state(board_buf).body_cache.D2)
  end)

  it("keeps the title input when the draft title is only whitespace", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local title_win, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "   " })
    key("<CR>")
    assert.same({ "GitHub projects: draft title must not be empty", vim.log.levels.ERROR }, notices[1])
    assert.equals(2, #pending)
    assert.is_nil(body_window())
    assert.equals(title_win, vim.api.nvim_get_current_win())
    assert.same({ "   " }, buffer_lines(title_buf))
  end)

  it("returns to the title with the body kept and cancels the draft flow", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local title_win, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "Draft" })
    key("<CR>")
    local _, body_buf = body_window()
    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "kept body" })
    key("q")
    assert.is_nil(body_window())
    assert.equals(title_win, vim.api.nvim_get_current_win())
    assert.is_true(float.is_open("projects-add:title:" .. board_buf))

    key("<CR>")
    local _, reopened = body_window()
    assert.same({ "kept body" }, buffer_lines(reopened))
    key("q")
    key("<C-c>")
    assert.is_nil(select_window())
    assert.is_nil(input_window())
    assert.is_nil(body_window())
    assert.equals(select(1, board_window()), vim.api.nvim_get_current_win())
    assert.equals(2, #pending)
  end)

  it("returns to the choice when the existing input is cancelled", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    key("<C-c>")
    assert.is_nil(input_window())
    assert.equals(select(1, select_window()), vim.api.nvim_get_current_win())
    assert.is_true(float.is_open("projects-add:select:" .. board_buf))
    assert.equals(2, #pending)
  end)

  it("closes the flow when the choice is cancelled", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("q")
    assert.is_nil(select_window())
    assert.equals(select(1, board_window()), vim.api.nvim_get_current_win())
    item_manage.open_add(board_buf)
    assert.is_not_nil(select_window())
    assert.equals(2, #pending)
  end)

  it("keeps the body and retries after a draft add failure", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local _, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "Retry draft" })
    key("<CR>")
    local body_win, body_buf = body_window()
    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "body" })
    key("<C-s>")
    fail(3, 1, "HTTP 403")
    assert.same(
      { "GitHub projects: permission denied: GitHub request failed (exit 1)", vim.log.levels.ERROR },
      notices[1]
    )
    assert.equals(body_win, vim.api.nvim_get_current_win())
    assert.same({ "body" }, buffer_lines(body_buf))
    assert.is_true(float.is_open("projects-add:title:" .. board_buf))

    key("<C-s>")
    assert.equals(4, #pending)
    respond(
      4,
      draft_item_response(item_node({
        id = "D3",
        type = "DRAFT_ISSUE",
        content = draft_content("Retry draft", "body"),
      }))
    )
    assert.equals("D3", board.selected_item(board_buf).id)
    assert.is_nil(body_window())
  end)

  it("ignores repeated draft submits while the request is in flight", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local _, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "Draft" })
    key("<CR>")
    key("<C-s>")
    key("<C-s>")
    assert.equals(3, #pending)
    respond(
      3,
      draft_item_response(item_node({
        id = "D4",
        type = "DRAFT_ISSUE",
        content = draft_content("Draft", ""),
      }))
    )
    assert.equals(5, #board.state(board_buf).items)
  end)

  it("selects the existing item instead of creating a duplicate", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(3, resolve_response("Issue", "NODE5"))
    respond(
      4,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Existing issue"),
      }))
    )

    item_manage.open_add(board_buf)
    key("<CR>")
    local _, second_input = input_window()
    vim.api.nvim_buf_set_lines(second_input, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(5, resolve_response("Issue", "NODE5"))
    respond(
      6,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Existing issue"),
      }))
    )

    local state = board.state(board_buf)
    assert.equals(5, #state.items)
    assert.same({ column_index = 1, item_id = "I5" }, state.selected)
    assert.equals(5, state.project.item_count)
    assert.same({ ADD_DUPLICATE, vim.log.levels.INFO }, notices[2])
    assert.is_nil(select_window())
    assert.is_nil(input_window())
  end)

  it("places an added item without a group value in the no-value column", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(3, resolve_response("Issue", "NODE5"))
    respond(
      4,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        no_values = true,
        content = issue_content(5, "No status"),
      }))
    )
    local state = board.state(board_buf)
    assert.same({ column_index = 4, item_id = "I5" }, state.selected)
    assert.equals(2, state.columns[4].count)
    assert.equals(5, state.project.item_count)
    assert.same({
      ADD_GROUP_MISSING,
      vim.log.levels.INFO,
    }, notices[1])
  end)

  it("does not add an item that does not match the current filter", function()
    local _, board_buf = prepare_board("label:bug")
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(4, resolve_response("Issue", "NODE5"))
    respond(
      5,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "No bug label"),
      }))
    )
    local state = board.state(board_buf)
    assert.equals(4, #state.items)
    assert.equals(5, state.project.item_count)
    assert.same({
      ADD_FILTER_MISMATCH,
      vim.log.levels.INFO,
    }, notices[1])
    assert.is_nil(select_window())
    assert.is_nil(input_window())
  end)

  it("adds an item that matches a label filter", function()
    local _, board_buf = prepare_board("label:bug")
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(4, resolve_response("Issue", "NODE5"))
    respond(
      5,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Bug issue", { totalCount = 1, nodes = { { name = "Bug", color = "ff0000" } } }),
      }))
    )
    local state = board.state(board_buf)
    assert.equals(5, #state.items)
    assert.same({ column_index = 1, item_id = "I5" }, state.selected)
    assert.equals(5, state.project.item_count)
    assert.same({
      ADD_SUCCESS,
      vim.log.levels.INFO,
    }, notices[1])
  end)

  it("matches status, assignee and negated status filters", function()
    local cases = {
      {
        filter = "status:Todo",
        option = "todo",
        option_name = "Todo",
        expected = true,
      },
      {
        filter = "status:Todo",
        option = "doing",
        option_name = "In Progress",
        expected = false,
      },
      {
        filter = "-status:Done",
        option = "todo",
        option_name = "Todo",
        expected = true,
      },
      {
        filter = "-status:Done",
        option = "done",
        option_name = "Done",
        expected = false,
      },
      {
        filter = "assignee:alice",
        assignees = { totalCount = 1, nodes = { { login = "alice" } } },
        expected = true,
      },
      {
        filter = "assignee:alice",
        assignees = { totalCount = 1, nodes = { { login = "bob" } } },
        expected = false,
      },
      {
        filter = "is:open",
        expected = true,
      },
    }
    for index, case in ipairs(cases) do
      close_all()
      calls, pending, notices = {}, {}, {}
      local _, board_buf = prepare_board(case.filter)
      item_manage.open_add(board_buf)
      key("<CR>")
      local _, input_buf = input_window()
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#" .. (10 + index) })
      key("<CR>")
      respond(4, resolve_response("Issue", "NODE" .. index))
      respond(
        5,
        added_item_response(item_node({
          id = "F" .. index,
          type = "ISSUE",
          option = case.option,
          option_name = case.option_name,
          content = issue_content(10 + index, "Filtered issue", nil, case.assignees),
        }))
      )
      local state = board.state(board_buf)
      if case.expected then
        local column = case.option == "doing" and 2
          or (case.option == "done" and 3 or (case.option == "todo" and 1 or 4))
        assert.same({ column_index = column, item_id = "F" .. index }, state.selected)
        assert.equals(5, #state.items)
        local notice = case.option == nil and ADD_GROUP_MISSING or ADD_SUCCESS
        assert.same({ notice, vim.log.levels.INFO }, notices[1])
      else
        assert.equals(4, #state.items)
        assert.equals(5, state.project.item_count)
        assert.same({ ADD_FILTER_MISMATCH, vim.log.levels.INFO }, notices[1])
      end
    end
  end)

  it("does not guess when the filter cannot be evaluated locally", function()
    local _, board_buf = prepare_board('label:"bug"')
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    respond(4, resolve_response("Issue", "NODE5"))
    respond(
      5,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Unknown filter"),
      }))
    )
    assert.equals(4, #board.state(board_buf).items)
    assert.equals(5, board.state(board_buf).project.item_count)
    assert.same({
      ADD_FILTER_UNKNOWN,
      vim.log.levels.INFO,
    }, notices[1])
  end)

  it("does not guess when the label or assignee list is truncated", function()
    local labels = {
      totalCount = 6,
      nodes = {
        { name = "a", color = "111111" },
        { name = "b", color = "111111" },
        { name = "c", color = "111111" },
        { name = "d", color = "111111" },
        { name = "e", color = "111111" },
      },
    }
    local assignees = {
      totalCount = 4,
      nodes = { { login = "bob" }, { login = "carol" }, { login = "dave" } },
    }
    local cases = {
      { filter = "label:bug", labels = labels },
      { filter = "-label:bug", labels = labels },
      { filter = "assignee:alice", assignees = assignees },
      { filter = "label:a", labels = labels, expected = true },
      { filter = "no:label", labels = labels, expected = false },
      { filter = "no:assignee", assignees = assignees, expected = false },
      { filter = "no:label", labels = { totalCount = 0, nodes = {} }, expected = true },
    }
    for index, case in ipairs(cases) do
      close_all()
      calls, pending, notices = {}, {}, {}
      local _, board_buf = prepare_board(case.filter)
      item_manage.open_add(board_buf)
      key("<CR>")
      local _, input_buf = input_window()
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#" .. (20 + index) })
      key("<CR>")
      respond(4, resolve_response("Issue", "NODE" .. index))
      respond(
        5,
        added_item_response(item_node({
          id = "T" .. index,
          type = "ISSUE",
          option = "todo",
          option_name = "Todo",
          content = issue_content(20 + index, "Truncated list", case.labels, case.assignees),
        }))
      )
      local state = board.state(board_buf)
      if case.expected then
        assert.equals(5, #state.items)
        assert.same({ column_index = 1, item_id = "T" .. index }, state.selected)
        assert.same({ ADD_SUCCESS, vim.log.levels.INFO }, notices[1])
      elseif case.expected == false then
        assert.equals(4, #state.items)
        assert.equals(5, state.project.item_count)
        assert.same({ ADD_FILTER_MISMATCH, vim.log.levels.INFO }, notices[1])
      else
        assert.equals(4, #state.items)
        assert.equals(5, state.project.item_count)
        assert.same({ ADD_FILTER_UNKNOWN, vim.log.levels.INFO }, notices[1])
      end
    end
  end)

  it("shows a delete confirmation for the selected item", function()
    local board_win, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    local win, buf = confirm_window()
    assert.is_not_nil(win)
    assert.same({ 47, 3 }, { vim.api.nvim_win_get_config(win).width, vim.api.nvim_win_get_config(win).height })
    assert.same({
      "Delete this item from the project?",
      "Issue #1 Fix bug",
      "y: delete  n/q/Esc: cancel",
    }, buffer_lines(buf))
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)
    assert_mapping(buf, "n", "y")
    assert_mapping(buf, "n", "n")
    assert_mapping(buf, "n", "q")
    assert_mapping(buf, "n", "<Esc>")
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.equals(2, #pending)

    key("n")
    assert.is_nil(confirm_window())
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.equals(2, #pending)
    assert.equals(4, #board.state(board_buf).items)

    item_manage.open_delete(board_buf)
    key("q")
    assert.is_nil(confirm_window())
    item_manage.open_delete(board_buf)
    key("<Esc>")
    assert.is_nil(confirm_window())
    assert.equals(2, #pending)
    assert.equals(4, #board.state(board_buf).items)
  end)

  it("deletes the selected item and moves the selection to the next item", function()
    local board_win, board_buf = prepare_board()
    board.state(board_buf).body_cache.I1 = "cached body"
    item_manage.open_delete(board_buf)
    key("y")
    assert.equals(3, #pending)
    assert.same({ projectId = "P1", itemId = "I1" }, vim.json.decode(calls[3].opts.stdin).variables)
    assert.is_true(vim.fn.stridx(calls[3].opts.stdin, "deleteProjectV2Item") > 0)
    respond(3, delete_response("I1"))

    local state = board.state(board_buf)
    assert.equals(3, #state.items)
    assert.same({ column_index = 1, item_id = "I3" }, state.selected)
    assert.equals(1, state.columns[1].count)
    assert.equals(3, state.project.item_count)
    assert.is_nil(state.body_cache.I1)
    assert.same({
      DELETE_SUCCESS,
      vim.log.levels.INFO,
    }, notices[1])
    assert.is_nil(confirm_window())
    assert.equals(board_win, vim.api.nvim_get_current_win())
  end)

  it("selects the previous item or the column header after a delete", function()
    local _, board_buf = prepare_board()
    board.select_item(board_buf, "I3")
    item_manage.open_delete(board_buf)
    key("y")
    respond(3, delete_response("I3"))
    local state = board.state(board_buf)
    assert.same({ column_index = 1, item_id = "I1" }, state.selected)
    assert.equals(1, state.columns[1].count)

    board.select_item(board_buf, "I2")
    item_manage.open_delete(board_buf)
    key("y")
    respond(4, delete_response("I2"))
    assert.same({ column_index = 2, item_id = nil }, board.state(board_buf).selected)
    assert.equals(0, board.state(board_buf).columns[2].count)
  end)

  it("does not open a confirmation when no item is selected", function()
    local _, board_buf = prepare_board()
    key("l")
    key("l")
    assert.same({ column_index = 3, item_id = nil }, board.state(board_buf).selected)
    item_manage.open_delete(board_buf)
    assert.same({ "GitHub projects: select an item to delete", vim.log.levels.ERROR }, notices[1])
    assert.is_nil(confirm_window())
    assert.equals(2, #pending)
  end)

  it("shows pull request, draft and redacted items in the confirmation", function()
    local _, board_buf = prepare_board()
    local cases = {
      { item = "I2", line = "Pull request #2 Add feature" },
      { item = "I3", line = "Draft issue Draft idea" },
      { item = "R1", line = "[redacted]" },
    }
    for _, case in ipairs(cases) do
      board.select_item(board_buf, case.item)
      item_manage.open_delete(board_buf)
      local _, buf = confirm_window()
      assert.equals(case.line, buffer_lines(buf)[2])
      key("q")
    end
  end)

  it("truncates a long confirmation title to the window width", function()
    local items = {
      item_node({
        id = "I1",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(1, "日本語のとても長いタイトルがここにあります"),
      }),
    }
    open_board(1)
    respond(1, detail_response(1, "Board", "", 1))
    respond(2, items_response(items, 1))
    local _, board_buf = board_window()
    item_manage.open_delete(board_buf)
    local _, buf = confirm_window()
    local line = buffer_lines(buf)[2]
    assert.is_true(vim.fn.strdisplaywidth(line) <= 47)
    assert.is_true(line:sub(-3) == "...")
  end)

  it("keeps the confirmation open and the model unchanged after a delete failure", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    fail(3, 1, "HTTP 403")
    assert.same(
      { "GitHub projects: permission denied: GitHub request failed (exit 1)", vim.log.levels.ERROR },
      notices[1]
    )
    assert.equals(4, #board.state(board_buf).items)
    assert.is_not_nil(confirm_window())

    key("y")
    assert.equals(4, #pending)
    respond(4, delete_response("I1"))
    assert.equals(3, #board.state(board_buf).items)
    assert.is_nil(confirm_window())
  end)

  it("does not treat a missing item as deleted", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    respond(3, { data = { deleteProjectV2Item = { deletedItemId = vim.NIL } } })
    assert.same({
      "GitHub projects: project item not found; run r to refresh",
      vim.log.levels.ERROR,
    }, notices[1])
    assert.equals(4, #board.state(board_buf).items)
    assert.is_not_nil(confirm_window())
  end)

  it("does not claim success when a delete result is unknown", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    fail(3, 1, "")
    assert.same({
      "GitHub projects: GitHub request failed (exit 1); run r to refresh",
      vim.log.levels.ERROR,
    }, notices[1])
    assert.equals(4, #board.state(board_buf).items)
    assert.is_not_nil(confirm_window())
  end)

  it("ignores repeated delete submits while the request is in flight", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    key("y")
    assert.equals(3, #pending)
    respond(3, delete_response("I1"))
    assert.equals(3, #board.state(board_buf).items)
  end)

  it("deletes a redacted item and moves to the column header", function()
    local _, board_buf = prepare_board()
    board.select_item(board_buf, "R1")
    item_manage.open_delete(board_buf)
    local _, buf = confirm_window()
    assert.equals("[redacted]", buffer_lines(buf)[2])
    key("y")
    respond(3, delete_response("R1"))
    local state = board.state(board_buf)
    assert.equals(3, #state.items)
    assert.same({ column_index = 4, item_id = nil }, state.selected)
    assert.equals(0, state.columns[4].count)
    assert.equals(3, state.project.item_count)
  end)

  it("reuses and focuses an open add flow or delete confirmation", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    local select_win = select_window()
    item_manage.open_add(board_buf)
    assert.equals(select_win, vim.api.nvim_get_current_win())
    key("<CR>")
    local input_win = input_window()
    item_manage.open_add(board_buf)
    assert.equals(input_win, vim.api.nvim_get_current_win())
    item_manage.open_delete(board_buf)
    assert.equals(input_win, vim.api.nvim_get_current_win())
    assert.is_nil(confirm_window())

    key("<C-c>")
    key("q")
    assert.is_nil(select_window())
    item_manage.open_delete(board_buf)
    local confirm_win = confirm_window()
    item_manage.open_delete(board_buf)
    assert.equals(confirm_win, vim.api.nvim_get_current_win())
    item_manage.open_add(board_buf)
    assert.equals(confirm_win, vim.api.nvim_get_current_win())
    assert.is_nil(select_window())
  end)

  it("adds a Japanese draft with a multiline body", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local _, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "日本語の下書き" })
    key("<CR>")
    local _, body_buf = body_window()
    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "本文の一行目", "本文の二行目" })
    key("<C-s>")
    assert.same({
      projectId = "P1",
      title = "日本語の下書き",
      body = "本文の一行目\n本文の二行目",
    }, vim.json.decode(calls[3].opts.stdin).variables)
    respond(
      3,
      draft_item_response(item_node({
        id = "D5",
        type = "DRAFT_ISSUE",
        content = draft_content("日本語の下書き", "本文の一行目\n本文の二行目"),
      }))
    )
    assert.equals("本文の一行目\n本文の二行目", board.state(board_buf).body_cache.D5)
  end)

  it("does not display a draft that does not match the current filter", function()
    local _, board_buf = prepare_board("label:bug")
    item_manage.open_add(board_buf)
    key("j")
    key("<CR>")
    local _, title_buf = input_window()
    vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "Filtered draft" })
    key("<CR>")
    key("<C-s>")
    respond(
      4,
      draft_item_response(item_node({
        id = "D6",
        type = "DRAFT_ISSUE",
        content = draft_content("Filtered draft", ""),
      }))
    )
    assert.equals(4, #board.state(board_buf).items)
    assert.equals(5, board.state(board_buf).project.item_count)
    assert.same({
      ADD_DRAFT_FILTER_MISMATCH,
      vim.log.levels.INFO,
    }, notices[1])
  end)

  it("does not update or recreate screens when the board closes before the add response", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    assert.equals(3, #pending)

    float.close("projects-board:github.com:alice:1")
    assert.is_nil(board.state(board_buf))
    assert.is_nil(select_window())
    assert.is_nil(input_window())
    assert.equals(0, #float_windows())

    respond(3, resolve_response("Issue", "NODE5"))
    assert.equals(3, #pending)
    assert.equals(0, #float_windows())
    assert.is_nil(board.state(board_buf))
  end)

  it("ignores a resolve response from a flow that was restarted", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#1" })
    key("<CR>")
    assert.equals(3, #pending)

    key("<C-c>")
    key("<CR>")
    local _, second_input = input_window()
    vim.api.nvim_buf_set_lines(second_input, 0, -1, false, { "a/r#2" })
    key("<CR>")
    assert.equals(4, #pending)

    respond(3, resolve_response("Issue", "NODE1"))
    assert.equals(4, #pending)
    respond(4, resolve_response("Issue", "NODE2"))
    assert.equals(5, #pending)
    respond(
      5,
      added_item_response(item_node({
        id = "I9",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(2, "Second reference"),
      }))
    )
    local state = board.state(board_buf)
    assert.equals(5, #state.items)
    assert.equals("I9", state.items[5].id)
    assert.equals("Second reference", state.items[5].content.title)
  end)

  it("does not update when the board closes before the delete response", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    assert.equals(3, #pending)
    float.close("projects-board:github.com:alice:1")
    assert.is_nil(board.state(board_buf))
    assert.equals(0, #float_windows())
    respond(3, delete_response("I1"))
    assert.equals(0, #float_windows())
    assert.is_nil(board.state(board_buf))
    assert.equals(0, #notices)
  end)

  it("opens the add and delete flows from the board keymaps", function()
    local _, board_buf = prepare_board()
    key("ghn")
    assert.is_not_nil(select_window())
    assert.is_true(float.is_open("projects-add:select:" .. board_buf))
    key("q")
    assert.is_nil(select_window())
    key("ghd")
    local _, buf = confirm_window()
    assert.same({
      "Delete this item from the project?",
      "Issue #1 Fix bug",
      "y: delete  n/q/Esc: cancel",
    }, buffer_lines(buf))
    key("n")
    assert.is_nil(confirm_window())
    assert.equals(2, #pending)
  end)

  it("distinguishes rate limit and validation failures", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    fail(3, 1, "HTTP 429")
    assert.same({
      "GitHub projects: rate limit exceeded: GitHub request failed (exit 1)",
      vim.log.levels.ERROR,
    }, notices[1])
    assert.is_not_nil(input_window())

    key("<CR>")
    assert.equals(4, #pending)
    fail(4, 1, "HTTP 422")
    assert.same({
      "GitHub projects: invalid request: GitHub request failed (exit 1)",
      vim.log.levels.ERROR,
    }, notices[2])
    assert.is_not_nil(input_window())
  end)

  it("closes the flow when the add response arrives in another tab", function()
    local _, board_buf = prepare_board()
    item_manage.open_add(board_buf)
    key("<CR>")
    local _, input_buf = input_window()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "a/r#5" })
    key("<CR>")
    vim.cmd("tabnew")
    respond(3, resolve_response("Issue", "NODE5"))
    respond(
      4,
      added_item_response(item_node({
        id = "I5",
        type = "ISSUE",
        option = "todo",
        option_name = "Todo",
        content = issue_content(5, "Other tab"),
      }))
    )
    assert.equals(5, #board.state(board_buf).items)
    assert.equals(1, #float_windows())
    vim.cmd("tabclose")
    assert.is_nil(select_window())
    assert.is_nil(input_window())
    assert.equals(1, #float_windows())
  end)

  it("closes the confirmation when the delete response arrives in another tab", function()
    local _, board_buf = prepare_board()
    item_manage.open_delete(board_buf)
    key("y")
    vim.cmd("tabnew")
    respond(3, delete_response("I1"))
    assert.equals(3, #board.state(board_buf).items)
    assert.equals(1, #float_windows())
    vim.cmd("tabclose")
    assert.is_nil(confirm_window())
    assert.equals(1, #float_windows())
  end)
end)
