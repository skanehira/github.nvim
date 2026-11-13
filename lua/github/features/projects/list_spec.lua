local process = require("github.core.process")
local config = require("github.core.config")
local ui = require("github.features.projects.ui")

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

local function window_in_tab(filetype, tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo[buf].filetype == filetype then
      return win, buf
    end
  end
end

local function current_window(filetype)
  return window_in_tab(filetype, vim.api.nvim_get_current_tabpage())
end

local function highlights(buf)
  local values = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
  do
    local row, col, detail = mark[2], mark[3], mark[4]
    local header = detail.hl_group == "GitHubProjectsHeader"
      or detail.hl_group == "GitHubProjectsLoading"
      or detail.hl_group == "GitHubProjectsError"
    if not header then
      local text = vim.api.nvim_buf_get_text(buf, row, col, row, detail.end_col, {})[1]
      values[#values + 1] = { row, text, detail.hl_group }
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

local function project_node(number, title, item_count, public, closed)
  return {
    id = "P" .. number,
    number = number,
    title = title,
    items = { totalCount = item_count },
    public = public,
    closed = closed or false,
    url = "https://github.com/users/alice/projects/" .. number,
  }
end

local function projects_page(nodes, has_next, cursor, total_count)
  return {
    data = {
      user = {
        projectsV2 = {
          totalCount = total_count or #nodes,
          pageInfo = { hasNextPage = has_next or false, endCursor = cursor or vim.NIL },
          nodes = nodes,
        },
      },
    },
  }
end

local function org_projects_page(nodes, has_next, cursor)
  return {
    data = {
      organization = {
        projectsV2 = {
          totalCount = #nodes,
          pageInfo = { hasNextPage = has_next or false, endCursor = cursor or vim.NIL },
          nodes = nodes,
        },
      },
    },
  }
end

local function status_field()
  return {
    __typename = "ProjectV2SingleSelectField",
    id = "status",
    name = "Status",
    dataType = "SINGLE_SELECT",
    options = { { id = "todo", name = "Todo", color = "GRAY" } },
  }
end

local function detail_response(number, title)
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
          items = { totalCount = 1 },
          fields = { nodes = { status_field() } },
          views = { nodes = {} },
        },
      },
    },
  }
end

local function issue_node(number, title, option_id)
  return {
    id = "I" .. number,
    type = "ISSUE",
    isArchived = false,
    content = {
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
    },
    fieldValues = {
      nodes = {
        {
          __typename = "ProjectV2ItemFieldSingleSelectValue",
          name = "Todo",
          optionId = option_id or "todo",
          field = { id = "status", name = "Status", dataType = "SINGLE_SELECT" },
        },
      },
    },
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

local function org_detail_response(number, title)
  return {
    data = {
      organization = detail_response(number, title).data.user,
    },
  }
end

local function org_items_response(nodes, total_count)
  return {
    data = {
      organization = items_response(nodes, total_count).data.user,
    },
  }
end

local function list_lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

describe("projects list", function()
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

  it("opens the authenticated user's projects with number, title, item count and visibility", function()
    vim.cmd("GitHub projects")
    assert.equals(0, #float_windows())
    assert.equals(1, #calls)
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "user" }, calls[1].argv)
    assert.is_nil(calls[1].opts.stdin)

    respond(1, { login = "alice", type = "User" })
    local win, buf = current_window("gh-projects-list")
    assert.is_not_nil(win)
    assert.same({ "Loading projects..." }, list_lines(win))
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)
    assert.equals("nofile", vim.bo[buf].buftype)
    for _, lhs in ipairs({ "j", "k", "<CR>", "r", "q", "<Esc>" }) do
      assert_mapping(buf, "n", lhs)
    end

    respond(
      2,
      projects_page({
        project_node(1, "First", 3, true),
        project_node(2, "Second", 5, false),
        project_node(3, "Closed", 1, true, true),
      })
    )
    assert.same({
      "Projects for alice (user)  ·  2 open",
      "#1 First  3 items  public",
      "#2 Second  5 items  private",
    }, list_lines(win))
    assert.same({ { 1, "#1 First  3 items  public", "GitHubProjectsCardSelected" } }, highlights(buf))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
    assert.equals("graphql", calls[2].argv[3])
    local query = vim.json.decode(calls[2].opts.stdin)
    assert.is_truthy(query.query:find("user(login:", 1, true))
    assert.same({ owner = "alice" }, query.variables)
    for _, call in ipairs(calls) do
      assert.equals("gh", call.argv[1])
    end
  end)

  it("opens an organization's projects", function()
    vim.cmd("GitHub projects acme")
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "users/acme" }, calls[1].argv)
    respond(1, { login = "acme", type = "Organization" })
    respond(2, org_projects_page({ project_node(4, "Org project", 2, false) }))
    local win = current_window("gh-projects-list")
    assert.same({
      "Projects for acme (organization)  ·  1 open",
      "#4 Org project  2 items  private",
    }, list_lines(win))
    local query = vim.json.decode(calls[2].opts.stdin)
    assert.is_truthy(query.query:find("organization(login:", 1, true))
    assert.same({ owner = "acme" }, query.variables)
  end)

  it("opens an organization's project board directly without the list", function()
    vim.cmd("GitHub projects acme 7")
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "users/acme" }, calls[1].argv)
    assert.equals(0, #float_windows())
    respond(1, { login = "acme", type = "Organization" })
    assert.is_nil(current_window("gh-projects-list"))
    assert.equals(2, #calls)
    assert.equals("graphql", calls[2].argv[3])
    local query = vim.json.decode(calls[2].opts.stdin)
    assert.is_truthy(query.query:find("organization(login:", 1, true))
    assert.same({ owner = "acme", number = 7 }, query.variables)

    respond(2, org_detail_response(7, "Org direct"))
    respond(3, org_items_response({ issue_node(1, "Org issue", "todo") }))
    local win = current_window("gh-projects-board")
    assert.is_not_nil(win)
    local rendered = list_lines(win)
    assert.equals("acme / Org direct  ·  1 items  ·  filter: ", rendered[1])
    assert.equals(ui.pad("● Todo 1", 36) .. "│" .. ui.pad("○ 値なし 0", 36), rendered[2])
    assert.equals(ui.pad("○ #1 Org issue", 36) .. "│" .. ui.pad("—", 36), rendered[3])
  end)

  it("shows an empty list, truncation and truncated titles", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({}))
    local win = current_window("gh-projects-list")
    assert.same({ "Projects for alice (user)  ·  0 open", "No open projects" }, list_lines(win))
    assert.same({}, highlights(vim.api.nvim_win_get_buf(win)))

    vim.cmd("GitHub projects bob")
    respond(3, { login = "bob", type = "User" })
    local nodes = {}
    for index = 1, 100 do
      nodes[index] = project_node(index, "Project " .. index, index, true)
    end
    respond(4, projects_page(nodes, true, "cursor"))
    win = current_window("gh-projects-list")
    local rendered = list_lines(win)
    assert.equals("Showing 100 projects", rendered[1])
    assert.equals(101, #rendered)
    assert.equals("#100 Project 100  100 items  public", rendered[101])

    vim.cmd("GitHub projects carol")
    respond(5, { login = "carol", type = "User" })
    local long_title = string.rep("x", 100)
    respond(6, projects_page({ project_node(7, long_title, 1, true) }))
    win = current_window("gh-projects-list")
    rendered = list_lines(win)
    assert.equals("Projects for carol (user)  ·  1 open", rendered[1])
    assert.equals("#7 " .. string.rep("x", 59) .. "...  1 items  public", rendered[2])
    assert.equals(82, vim.fn.strdisplaywidth(rendered[2]))
  end)

  it("moves the selection with j and k and stops at both ends", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(
      2,
      projects_page({
        project_node(1, "One", 0, true),
        project_node(2, "Two", 0, true),
        project_node(3, "Three", 0, true),
      })
    )
    local win, buf = current_window("gh-projects-list")
    key("k")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
    key("j")
    key("j")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(win))
    assert.same({ { 3, "#3 Three  0 items  public", "GitHubProjectsCardSelected" } }, highlights(buf))
    key("j")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(win))
    key("k")
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("keeps the selection by project number on refresh and clamps when it disappears", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(
      2,
      projects_page({
        project_node(1, "One", 0, true),
        project_node(2, "Two", 0, true),
        project_node(3, "Three", 0, true),
      })
    )
    local win, buf = current_window("gh-projects-list")
    key("j")
    key("j")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(win))

    key("r")
    assert.same({
      "Loading projects...",
      "#1 One  0 items  public",
      "#2 Two  0 items  public",
      "#3 Three  0 items  public",
    }, list_lines(win))
    respond(
      3,
      projects_page({
        project_node(3, "Three", 0, true),
        project_node(1, "One", 0, true),
        project_node(2, "Two", 0, true),
      })
    )
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
    assert.same({ { 1, "#3 Three  0 items  public", "GitHubProjectsCardSelected" } }, highlights(buf))

    key("j")
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(win))
    key("r")
    respond(4, projects_page({ project_node(2, "Two", 0, true), project_node(3, "Three", 0, true) }))
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(win))
    assert.same({ { 2, "#3 Three  0 items  public", "GitHubProjectsCardSelected" } }, highlights(buf))

    key("r")
    respond(5, projects_page({}))
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
    assert.same({}, highlights(buf))
    assert.same({ "Projects for alice (user)  ·  0 open", "No open projects" }, list_lines(win))
  end)

  it("shows failures in the header and keeps the previous rows on refresh failure", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({ project_node(1, "One", 0, true) }))
    local win = current_window("gh-projects-list")
    key("r")
    fail(3, 1, "HTTP 403")
    assert.same({
      "Error: GitHub request failed (exit 1)",
      "#1 One  0 items  public",
    }, list_lines(win))

    vim.cmd("GitHub projects bob")
    respond(4, { login = "bob", type = "User" })
    fail(5, 1, "")
    local failed = current_window("gh-projects-list")
    assert.same({
      "Error: GitHub request failed (exit 1)",
      "No open projects",
    }, list_lines(failed))
  end)

  it("reuses the same owner's list and refetches it", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({ project_node(1, "One", 0, true) }))
    local win, buf = current_window("gh-projects-list")

    vim.cmd("GitHub projects")
    respond(3, { login = "alice", type = "User" })
    assert.same({ "Loading projects...", "#1 One  0 items  public" }, list_lines(win))
    respond(4, projects_page({ project_node(2, "Two", 1, true) }))
    assert.same({ win, buf }, { current_window("gh-projects-list") })
    assert.same({
      "Projects for alice (user)  ·  1 open",
      "#2 Two  1 items  public",
    }, list_lines(win))
    assert.equals(4, #calls)
  end)

  it("does not open the list when gh is unauthenticated or the owner is unavailable", function()
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("GitHub projects")
    fail(1, 4, "gh auth login required")
    assert.equals(0, #float_windows())
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.same({
      { "GitHub projects: gh is not authenticated; run gh auth login --hostname github.com", vim.log.levels.ERROR },
    }, notices)

    vim.cmd("GitHub projects missing")
    fail(2, 1, "HTTP 404")
    assert.equals(0, #float_windows())
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.same({ "GitHub projects: GitHub request failed (exit 1)", vim.log.levels.ERROR }, notices[2])

    vim.cmd("GitHub projects secret")
    fail(3, 1, "HTTP 403")
    assert.equals(0, #float_windows())
    assert.equals(3, #notices)
  end)

  it("shows usage for invalid arguments without calling gh", function()
    local buf = vim.api.nvim_get_current_buf()
    for _, args in ipairs({
      "a b c",
      "a/b",
      "a b",
      "a 0",
      "a -1",
      "a 1.5",
      '""',
      '" "',
      "a_b",
      "a.b",
      "a b c d",
    }) do
      vim.cmd("GitHub projects " .. args)
    end
    assert.equals(11, #notices)
    for _, notice in ipairs(notices) do
      assert.equals("Usage: GitHub projects [owner] [number]", notice[1])
      assert.equals(vim.log.levels.ERROR, notice[2])
    end
    assert.equals(0, #calls)
    assert.equals(0, #float_windows())
    assert.equals(buf, vim.api.nvim_get_current_buf())
  end)

  it("treats @me and a bare number as the authenticated user", function()
    vim.cmd("GitHub projects @me")
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "user" }, calls[1].argv)
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({}))

    vim.cmd("GitHub projects 7")
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "user" }, calls[3].argv)
    respond(3, { login = "alice", type = "User" })
    respond(4, detail_response(7, "Direct"))
    respond(5, items_response({ issue_node(1, "Only issue", "todo") }))
    local board_win = current_window("gh-projects-board")
    assert.is_not_nil(board_win)
    assert.equals("alice / Direct  ·  1 items  ·  filter: ", list_lines(board_win)[1])

    vim.cmd("GitHub projects @me 8")
    assert.same({ "gh", "api", "--hostname", "github.com", "--method", "GET", "user" }, calls[6].argv)
    respond(6, { login = "alice", type = "User" })
    respond(7, detail_response(8, "Second direct"))
    respond(8, items_response({ issue_node(2, "Other issue", "todo") }))
  end)

  it("opens the selected project's board from the list and returns to the parent window", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(
      2,
      projects_page({
        project_node(1, "One", 1, true),
        project_node(2, "Two", 1, true),
      })
    )
    local list_win = current_window("gh-projects-list")
    key("j")
    key("<CR>")
    respond(3, detail_response(2, "Two"))
    respond(4, items_response({ issue_node(1, "Only issue", "todo") }))
    local board_win = current_window("gh-projects-board")
    assert.is_not_nil(board_win)
    assert.is_true(vim.api.nvim_win_is_valid(list_win))
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.equals("alice / Two  ·  1 items  ·  filter: ", list_lines(board_win)[1])

    key("q")
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(list_win, vim.api.nvim_get_current_win())
    key("<Esc>")
    assert.is_nil(current_window("gh-projects-list"))
    assert.equals(parent, vim.api.nvim_get_current_win())
  end)

  it("does not open a board for a missing or closed project", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("GitHub projects alice 5")
    respond(1, { login = "alice", type = "User" })
    respond(2, {
      data = { user = { projectV2 = vim.NIL } },
    })
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.same({ "GitHub projects: project not found", vim.log.levels.ERROR }, notices[1])

    vim.cmd("GitHub projects alice 6")
    respond(3, { login = "alice", type = "User" })
    local detail = detail_response(6, "Closed")
    detail.data.user.projectV2.closed = true
    respond(4, detail)
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.same({ "GitHub projects: Project #6 is closed", vim.log.levels.ERROR }, notices[2])
  end)

  it("repositions the list and board after VimResized and keeps the list selection", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(
      2,
      projects_page({
        project_node(1, string.rep("a", 60), 1, true),
        project_node(2, string.rep("b", 60), 1, true),
      })
    )
    local list_win = current_window("gh-projects-list")
    key("j")
    key("<CR>")
    respond(3, detail_response(2, "Two"))
    respond(4, items_response({ issue_node(1, "Only issue", "todo") }))
    local board_win = current_window("gh-projects-board")

    vim.o.columns, vim.o.lines = 80, 24
    vim.api.nvim_exec_autocmds("VimResized", {})

    for _, win in ipairs({ list_win, board_win }) do
      local win_config = vim.api.nvim_win_get_config(win)
      assert.is_true(win_config.width >= 1)
      assert.is_true(win_config.height >= 1)
      assert.is_true(win_config.col + win_config.width <= vim.o.columns)
      assert.is_true(win_config.row + win_config.height <= vim.o.lines)
    end
    assert.equals(54, vim.api.nvim_win_get_config(list_win).width)
    assert.equals(70, vim.api.nvim_win_get_config(board_win).width)
    local rendered = list_lines(list_win)
    assert.equals("Projects for alice (user)  ·  2 open", rendered[1])
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(list_win))
    assert.same({
      { 2, "#2 " .. string.rep("b", 31) .. "...  1 items  public", "GitHubProjectsCardSelected" },
    }, highlights(vim.api.nvim_win_get_buf(list_win)))
    assert.equals(36, vim.fn.strdisplaywidth(list_lines(board_win)[2]))
  end)

  it("ignores responses for a board or list that was closed before the response arrived", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({ project_node(1, "One", 1, true) }))
    local list_win = current_window("gh-projects-list")
    key("<CR>")
    respond(3, detail_response(1, "One"))
    local board_win = current_window("gh-projects-board")
    assert.is_not_nil(board_win)
    key("q")
    assert.is_nil(current_window("gh-projects-board"))
    respond(4, items_response({ issue_node(1, "Late issue", "todo") }))
    assert.is_nil(current_window("gh-projects-board"))
    assert.equals(list_win, vim.api.nvim_get_current_win())
    assert.same({ "Projects for alice (user)  ·  1 open", "#1 One  1 items  public" }, list_lines(list_win))

    key("r")
    key("q")
    assert.is_nil(current_window("gh-projects-list"))
    assert.equals(parent, vim.api.nvim_get_current_win())
    respond(5, projects_page({ project_node(9, "Late", 0, true) }))
    assert.is_nil(current_window("gh-projects-list"))
  end)

  it("does not open the list when the owner resolves in another tab", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("GitHub projects")
    vim.cmd("tabnew")
    local other = vim.api.nvim_get_current_win()
    respond(1, { login = "alice", type = "User" })
    assert.equals(0, #float_windows())
    assert.equals(1, #calls)
    assert.equals(other, vim.api.nvim_get_current_win())

    vim.cmd("tabnext 1")
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())
  end)

  it("does not open the list when the parent window was closed before the owner resolves", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(parent)
    vim.cmd("GitHub projects")
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_close(parent, true)
    respond(1, { login = "alice", type = "User" })
    assert.equals(0, #float_windows())
    assert.equals(1, #calls)
    assert.equals(other, vim.api.nvim_get_current_win())
  end)

  it("does not open a board when the list is closed before the project detail arrives", function()
    local parent = vim.api.nvim_get_current_win()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({ project_node(1, "One", 1, true) }))
    assert.is_not_nil(current_window("gh-projects-list"))
    key("<CR>")
    key("q")
    assert.is_nil(current_window("gh-projects-list"))
    assert.equals(parent, vim.api.nvim_get_current_win())

    respond(3, detail_response(1, "One"))
    assert.equals(0, #float_windows())
    assert.equals(3, #calls)
    assert.equals(parent, vim.api.nvim_get_current_win())
  end)

  it("does not operate on screens in another tab", function()
    vim.cmd("GitHub projects")
    respond(1, { login = "alice", type = "User" })
    respond(2, projects_page({ project_node(1, "One", 0, true) }))
    local first_win, first_buf = current_window("gh-projects-list")
    local first_lines = list_lines(first_win)

    vim.cmd("tabnew")
    vim.cmd("GitHub projects")
    respond(3, { login = "alice", type = "User" })
    respond(4, projects_page({ project_node(2, "Two", 0, true) }))
    local second_win, second_buf = current_window("gh-projects-list")
    assert.is_true(first_win ~= second_win)
    assert.is_true(first_buf ~= second_buf)
    assert.same({ "Projects for alice (user)  ·  1 open", "#2 Two  0 items  public" }, list_lines(second_win))

    key("r")
    respond(5, projects_page({ project_node(3, "Three", 0, true) }))
    assert.same({ "Projects for alice (user)  ·  1 open", "#3 Three  0 items  public" }, list_lines(second_win))

    vim.cmd("tabnext 1")
    assert.same(first_lines, list_lines(first_win))
    assert.same({ { 1, "#1 One  0 items  public", "GitHubProjectsCardSelected" } }, highlights(first_buf))
  end)
end)
