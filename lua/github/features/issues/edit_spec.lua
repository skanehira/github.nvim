local old_choose
local old_columns
local calls, pending, notices, old_run, old_notify
local LEFT_CAP = "\u{E0B6}"
local RIGHT_CAP = "\u{E0B4}"
local function response(index, data)
  calls[index].done = true
  pending[index]({ code = 0, stdout = vim.json.encode({ data = data }) })
end
local function respond_to(pattern, data)
  for index, call in ipairs(calls) do
    if not call.done and call.body.query:find(pattern, 1, true) then
      return response(index, data)
    end
  end
  error("no pending call matching " .. pattern)
end
local function virtual_lines(buf)
  local namespace = vim.api.nvim_get_namespaces().github_issue_detail
  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  local lines = {}
  for _, mark in ipairs(marks) do
    local virtual = mark[4].virt_lines
    if virtual then
      for _, chunks in ipairs(virtual) do
        local text = ""
        for _, chunk in ipairs(chunks) do
          text = text .. chunk[1]
        end
        lines[#lines + 1] = text
      end
    end
  end
  return lines
end
local function header(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 4, false)
  vim.list_extend(lines, virtual_lines(buf))
  return lines
end
local function issue()
  return {
    id = "I1",
    number = 1,
    title = "Title",
    body = "body",
    state = "OPEN",
    url = "url",
    repository = { name = "r", owner = { login = "a" } },
    comments = { totalCount = 0 },
    assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
end
local function list()
  vim.cmd("edit github://a/r/issues")
  response(#calls, { search = { nodes = { issue() } } })
end
local function loaded(index, title, body)
  response(index, { repository = { issue = { id = "I1", title = title or "Title", body = body or "body" } } })
end
describe("issue editing", function()
  before_each(function()
    old_choose = require("github.core.navigation").choose
    require("github.core.navigation").choose = function(callback)
      callback("edit")
    end
    old_columns = vim.o.columns
    calls, pending, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin), done = false }
      pending[#pending + 1] = cb
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.navigation").choose = old_choose
    vim.o.columns = old_columns
    vim.notify = old_notify
    require("github.core.process").run = old_run
    require("github.core.cache").clear()
    vim.cmd("silent! %bwipeout!")
  end)
  it("opens title from list, validates it and updates title only", function()
    list()
    vim.cmd("normal ght")
    assert.equals(2, #calls)
    loaded(2)
    assert.same({ "Title" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "   " })
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #1: title must be one nonblank line", notices[#notices])
    assert.same({ "   " }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b" })
    vim.cmd("write")
    assert.equals(2, #calls)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "New title" })
    vim.cmd("write")
    assert.same({ id = "I1", title = "New title" }, calls[3].body.variables.input)
    response(3, { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: title saved", notices[#notices])
  end)
  it("opens body from URI and saves empty text without sending title", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1, "Title", "日本語\nsecond")
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "日本語", "second" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    assert.equals("markdown", vim.bo.filetype)
    vim.api.nvim_buf_set_lines(0, 4, -1, false, { "" })
    vim.cmd("write")
    assert.same({ id = "I1", body = "" }, calls[2].body.variables.input)
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: saved", notices[#notices])
  end)
  it("preserves pending edits, blocks duplicate writes, and retains content after failure", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    vim.api.nvim_buf_set_lines(0, 4, -1, false, { "draft" })
    vim.cmd("write")
    vim.api.nvim_buf_set_lines(0, 5, 5, false, { "later" })
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #1: save already in progress", notices[#notices])
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_true(vim.bo.modified)
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "draft", "later" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    vim.cmd("write")
    pending[3]({ code = 1, stdout = "" })
    assert.is_true(vim.bo.modified)
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "draft", "later" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    assert.equals("GitHub a/r #1: GitHub request failed (exit 1)", notices[#notices])
    assert.is_false(pcall(vim.cmd, "bdelete"))
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "draft", "later" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
  end)
  it("blocks body editing when selection exists and opens current issue when selection cleared", function()
    list()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-j>", true, false, true), "xt", false)
    vim.cmd("normal ghe")
    assert.equals(1, #calls)
    assert.equals("GitHub a/r: clear the selection before editing the body", notices[#notices])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-k>", true, false, true), "xt", false)
    vim.cmd("normal ghe")
    assert.equals(2, #calls)
    loaded(2)
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "body" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
  end)
  it("rejects writes after failed initial title and body reads", function()
    list()
    vim.cmd("normal ght")
    pending[2]({ code = 1, stdout = "" })
    assert.equals("GitHub a/r #1: GitHub request failed (exit 1)", notices[#notices])
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #1: issue not loaded", notices[#notices])
    vim.cmd("enew!")
    vim.cmd("edit github://a/r/issues/1")
    pending[3]({ code = 1, stdout = "" })
    assert.equals("GitHub a/r #1: GitHub request failed (exit 1)", notices[#notices])
    vim.cmd("write")
    assert.equals(3, #calls)
    assert.equals("GitHub a/r #1: issue not loaded", notices[#notices])
  end)
  it("retains unsaved body when asked to reload and keeps it writable", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    vim.api.nvim_buf_set_lines(0, 4, -1, false, { "作業中", "改行" })
    local buf = vim.api.nvim_get_current_buf()
    require("github.features.issues.edit").read(
      buf,
      { kind = "issue_edit", host = "github.com", owner = "a", repo = "r", issue_number = 1 }
    )
    assert.equals(1, #calls)
    assert.equals("GitHub a/r #1: unsaved changes retained", notices[#notices])
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "作業中", "改行" },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
    vim.cmd("write")
    assert.same({ id = "I1", body = "作業中\n改行" }, calls[2].body.variables.input)
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
  end)
  it("reports a missing issue response without enabling an empty write", function()
    vim.cmd("edit github://a/r/issues/1")
    response(1, { repository = vim.NIL })
    assert.equals("GitHub a/r #1: issue not found or invalid response", notices[#notices])
    vim.cmd("write")
    assert.equals("GitHub a/r #1: issue not loaded", notices[#notices])
    assert.equals(1, #calls)
  end)
  it("reloads a clean title buffer when reopened and preserves a dirty title", function()
    list()
    local listbuf = vim.api.nvim_get_current_buf()
    vim.cmd("normal ght")
    loaded(2)
    local titlebuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(listbuf)
    vim.cmd("normal ght")
    assert.equals(3, #calls)
    loaded(3, "Updated")
    assert.same({ "Updated" }, vim.api.nvim_buf_get_lines(titlebuf, 0, -1, false))
    vim.api.nvim_buf_set_lines(titlebuf, 0, -1, false, { "unsaved" })
    vim.api.nvim_set_current_buf(listbuf)
    vim.cmd("normal ght")
    assert.equals(3, #calls)
    assert.same({ "unsaved" }, vim.api.nvim_buf_get_lines(titlebuf, 0, -1, false))
    assert.is_true(vim.bo[titlebuf].modified)
  end)
  it("renders the editable header with the issue state above it", function()
    vim.cmd("edit github://a/r/issues/1")
    response(1, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "Title",
          state = "OPEN",
          body = "body",
          assignees = { nodes = { { login = "alice" }, { login = "bob" } } },
          labels = {
            totalCount = 2,
            nodes = {
              { name = "bug", color = "ff0000" },
              { name = "help wanted", color = "00ff00" },
            },
          },
          projectItems = {
            nodes = {
              {
                id = "PVTI_1",
                project = { id = "PVT_1", title = "Roadmap" },
                fieldValues = { nodes = { { name = "In progress", field = { id = "PVTF_1", name = "Status" } } } },
              },
            },
          },
        },
      },
    })
    assert.same({
      "Title",
      "Assignees   @alice, @bob",
      "Labels      " .. LEFT_CAP .. "bug" .. RIGHT_CAP .. ", " .. LEFT_CAP .. "help wanted" .. RIGHT_CAP,
      "Projects    Roadmap  ·  Status: In progress",
      "body",
    }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local text = table.concat(header(vim.api.nvim_get_current_buf()), "\n")
    assert.is_truthy(text:find("● Open", 1, true))
    assert.is_truthy(text:find("#1", 1, true))
    assert.is_truthy(text:find("a/r", 1, true))
    assert.is_truthy(text:find("@alice", 1, true))
    assert.is_truthy(text:find("@bob", 1, true))
    assert.is_truthy(text:find("bug", 1, true))
    assert.is_truthy(text:find("help wanted", 1, true))
    assert.is_truthy(text:find("Roadmap", 1, true))
    assert.is_truthy(text:find("Status: In progress", 1, true))
    assert.is_true(vim.wo.wrap)
  end)
  it("renders a closed state and empty metadata", function()
    vim.cmd("edit github://a/r/issues/2")
    response(1, {
      repository = {
        issue = {
          id = "I2",
          number = 2,
          title = "Closed title",
          state = "CLOSED",
          body = "",
          assignees = { nodes = {} },
          labels = { totalCount = 0, nodes = {} },
          projectItems = { nodes = {} },
        },
      },
    })
    local text = table.concat(header(vim.api.nvim_get_current_buf()), "\n")
    assert.is_truthy(text:find("● Closed", 1, true))
    assert.is_truthy(text:find("Assignees   —", 1, true))
    assert.is_truthy(text:find("Labels      —", 1, true))
    assert.is_truthy(text:find("Projects    —", 1, true))
    assert.same(
      { "Closed title", "Assignees   —", "Labels      —", "Projects    —", "" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
  end)
  it("falls back to the query without projects when the token lacks the project scope", function()
    vim.cmd("edit github://a/r/issues/1")
    pending[1]({
      code = 0,
      stdout = vim.json.encode({ errors = { { message = "Missing 'read:project' scope" } } }),
    })
    assert.equals(2, #calls)
    assert.is_falsy(calls[2].body.query:find("projectItems", 1, true))
    response(2, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "Title",
          state = "OPEN",
          body = "body",
          assignees = { nodes = {} },
          labels = { totalCount = 0, nodes = {} },
        },
      },
    })
    local text = table.concat(header(vim.api.nvim_get_current_buf()), "\n")
    assert.is_truthy(text:find("Projects    —", 1, true))
    assert.same(
      { "Title", "Assignees   —", "Labels      —", "Projects    —", "body" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    assert.equals(0, #notices)
  end)
  it("keeps the state and separator within the window width", function()
    vim.o.columns = 40
    vim.cmd("edit github://a/r/issues/1")
    response(1, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "A very long issue title that should wrap across lines",
          state = "OPEN",
          body = "body",
          assignees = { nodes = { { login = "a-very-long-login-name" } } },
          labels = {
            totalCount = 2,
            nodes = { { name = "bug", color = "ff0000" }, { name = "help wanted", color = "00ff00" } },
          },
          projectItems = {
            nodes = {
              {
                id = "PVTI_1",
                project = { id = "PVT_1", title = "A project with a long title" },
                fieldValues = { nodes = { { name = "In progress", field = { id = "PVTF_1", name = "Status" } } } },
              },
            },
          },
        },
      },
    })
    local lines = virtual_lines(vim.api.nvim_get_current_buf())
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 40)
    end
    assert.equals(40, vim.fn.strdisplaywidth(lines[4]))
  end)
  it("reapplies the header width after a resize", function()
    vim.o.columns = 80
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    local buf = vim.api.nvim_get_current_buf()
    local before = vim.fn.strdisplaywidth(virtual_lines(buf)[4])
    vim.o.columns = 40
    vim.api.nvim_exec_autocmds("VimResized", {})
    local after = vim.fn.strdisplaywidth(virtual_lines(buf)[4])
    assert.equals(40, after)
    assert.is_true(before > after)
  end)
  it("edits the title line and saves it together with the body", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "New title" })
    vim.api.nvim_buf_set_lines(0, 4, -1, false, { "edited" })
    vim.cmd("write")
    assert.same({ id = "I1", title = "New title", body = "edited" }, calls[2].body.variables.input)
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: saved", notices[#notices])
    assert.same(
      { "New title", "Assignees   —", "Labels      —", "Projects    —", "edited" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
  end)
  it("refuses to save the body when the header lines are missing", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    vim.cmd("write")
    assert.equals(1, #calls)
    assert.equals("GitHub a/r #1: restore the Assignees header line", notices[#notices])
  end)
  it("edits assignees and labels and resolves them from cached candidates", function()
    vim.cmd("edit github://a/r/issues/1")
    response(1, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "Title",
          state = "OPEN",
          body = "body",
          assignees = { nodes = {} },
          labels = { totalCount = 0, nodes = {} },
          projectItems = { nodes = {} },
        },
      },
    })
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "Assignees   @alice" })
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "Labels      bug" })
    vim.cmd("write")
    respond_to("assignableUsers", {
      repository = {
        assignableUsers = { nodes = { { id = "U1", login = "alice" } }, pageInfo = { hasNextPage = false } },
      },
    })
    respond_to("labels(first", {
      repository = {
        labels = { nodes = { { id = "L1", name = "bug", color = "ff0000" } }, pageInfo = { hasNextPage = false } },
      },
    })
    respond_to("updateIssue", { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: saved", notices[#notices])
    local update
    for _, call in ipairs(calls) do
      if call.body.query:find("updateIssue", 1, true) then
        update = call
      end
    end
    assert.same({ id = "I1", assigneeIds = { "U1" }, labelIds = { "L1" } }, update.body.variables.input)
    assert.same({
      "Title",
      "Assignees   @alice",
      "Labels      " .. LEFT_CAP .. "bug" .. RIGHT_CAP,
      "Projects    —",
      "body",
    }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("adds a project and updates its status with parallel mutations", function()
    vim.cmd("edit github://a/r/issues/1")
    response(1, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "Title",
          state = "OPEN",
          body = "body",
          assignees = { nodes = {} },
          labels = { totalCount = 0, nodes = {} },
          projectItems = {
            nodes = {
              {
                id = "PVTI_1",
                project = { id = "PVT_1", title = "Roadmap" },
                fieldValues = {
                  nodes = { { name = "Todo", optionId = "OPT_TODO", field = { id = "PVTF_1", name = "Status" } } },
                },
              },
            },
          },
        },
      },
    })
    assert.equals("Projects    Roadmap  ·  Status: Todo", vim.api.nvim_buf_get_lines(0, 3, 4, false)[1])
    vim.api.nvim_buf_set_lines(0, 3, 4, false, { "Projects    Roadmap  ·  Status: In progress, Ideas" })
    vim.cmd("write")
    respond_to("projectsV2", {
      repository = {
        projectsV2 = { nodes = { { id = "PVT_2", title = "Ideas" } }, pageInfo = { hasNextPage = false } },
      },
    })
    respond_to("fields(first", {
      node = {
        fields = {
          nodes = {
            {
              id = "PVTF_1",
              name = "Status",
              options = { { id = "OPT_TODO", name = "Todo" }, { id = "OPT_IN_PROGRESS", name = "In progress" } },
            },
          },
          pageInfo = { hasNextPage = false },
        },
      },
    })
    respond_to("updateProjectV2ItemFieldValue", {
      updateProjectV2ItemFieldValue = { projectV2Item = { id = "PVTI_1" } },
    })
    respond_to("addProjectV2ItemById", { addProjectV2ItemById = { item = { id = "PVTI_2" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: saved", notices[#notices])
    local update_call, add_call
    for _, call in ipairs(calls) do
      if call.body.query:find("updateProjectV2ItemFieldValue", 1, true) then
        update_call = call
      end
      if call.body.query:find("addProjectV2ItemById", 1, true) then
        add_call = call
      end
    end
    assert.same({
      projectId = "PVT_1",
      itemId = "PVTI_1",
      fieldId = "PVTF_1",
      value = { singleSelectOptionId = "OPT_IN_PROGRESS" },
    }, update_call.body.variables)
    assert.same({ projectId = "PVT_2", contentId = "I1" }, add_call.body.variables)
    assert.same({
      "Title",
      "Assignees   —",
      "Labels      —",
      "Projects    Roadmap  ·  Status: In progress, Ideas",
      "body",
    }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("computes completion start columns for each header field", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    local complete = require("github.features.issues.complete")
    local function start_at(line_index, text)
      vim.api.nvim_buf_set_lines(0, line_index, line_index + 1, false, { text })
      vim.api.nvim_win_set_cursor(0, { line_index + 1, #text })
      return complete.omnifunc(1, "")
    end
    assert.equals(12, start_at(1, "Assignees   @ali"))
    assert.equals(15, start_at(2, "Labels      " .. LEFT_CAP .. "bu"))
    assert.equals(12, start_at(3, "Projects    Road"))
    assert.equals(33, start_at(3, "Projects    Roadmap  ·  Status: In"))
  end)
  local roadmap_item = {
    id = "PVTI_1",
    project = { id = "PVT_1", title = "Roadmap" },
    fieldValues = { nodes = { { name = "Todo", optionId = "OPT_TODO", field = { id = "PVTF_1", name = "Status" } } } },
  }
  local status_fields = {
    node = {
      fields = {
        nodes = {
          {
            id = "PVTF_1",
            name = "Status",
            options = { { id = "OPT_TODO", name = "Todo" }, { id = "OPT_IN_PROGRESS", name = "In progress" } },
          },
        },
        pageInfo = { hasNextPage = false },
      },
    },
  }
  local projects_list = {
    repository = {
      projectsV2 = {
        nodes = { { id = "PVT_1", title = "Roadmap" }, { id = "PVT_2", title = "Ideas" } },
        pageInfo = { hasNextPage = false },
      },
    },
  }
  local completion_cases = {
    {
      name = "an assignee",
      line = 1,
      typed = "Assignees   @al",
      responses = {
        {
          "assignableUsers",
          {
            repository = {
              assignableUsers = {
                nodes = { { id = "U2", login = "bob" }, { id = "U1", login = "alice" } },
                pageInfo = { hasNextPage = false },
              },
            },
          },
        },
      },
      expected = "Assignees   @alice",
    },
    {
      name = "a label",
      line = 2,
      typed = "Labels      bu",
      responses = {
        {
          "labels(first",
          {
            repository = {
              labels = {
                nodes = {
                  { id = "L2", name = "enhancement", color = "00ff00" },
                  { id = "L1", name = "bug", color = "ff0000" },
                },
                pageInfo = { hasNextPage = false },
              },
            },
          },
        },
      },
      expected = "Labels      bug",
    },
    {
      name = "a project",
      line = 3,
      typed = "Projects    Id",
      responses = { { "projectsV2", projects_list } },
      expected = "Projects    Ideas",
    },
    {
      name = "a status of the current project",
      line = 3,
      project_items = { roadmap_item },
      typed = "Projects    Roadmap  ·  Status: In",
      responses = { { "fields(first", status_fields } },
      expected = "Projects    Roadmap  ·  Status: In progress",
    },
    {
      name = "a status of a project found in the project list",
      line = 3,
      typed = "Projects    Ideas  ·  Status: In",
      responses = { { "projectsV2", projects_list }, { "fields(first", status_fields } },
      expected = "Projects    Ideas  ·  Status: In progress",
    },
  }
  local function open_for_completion(case)
    vim.cmd("edit github://a/r/issues/1")
    response(1, {
      repository = {
        issue = {
          id = "I1",
          number = 1,
          title = "Title",
          state = "OPEN",
          body = "body",
          assignees = { nodes = {} },
          labels = { totalCount = 0, nodes = {} },
          projectItems = { nodes = case.project_items or {} },
        },
      },
    })
    vim.api.nvim_buf_set_lines(0, case.line, case.line + 1, false, { case.typed })
    vim.api.nvim_win_set_cursor(0, { case.line + 1, 0 })
  end
  local function respond_all(case)
    for _, item in ipairs(case.responses) do
      respond_to(item[1], item[2])
    end
  end
  for _, case in ipairs(completion_cases) do
    it("completes " .. case.name .. " with CTRL-X CTRL-O when the candidates arrive while still inserting", function()
      open_for_completion(case)
      vim.defer_fn(function()
        respond_all(case)
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "t", false)
      end, 20)
      vim.api.nvim_feedkeys(vim.keycode("A<C-x><C-o>"), "xt!", false)
      assert.same({ case.expected }, vim.api.nvim_buf_get_lines(0, case.line, case.line + 1, false))
    end)
    it("completes " .. case.name .. " with CTRL-X CTRL-O when the candidates are already cached", function()
      open_for_completion(case)
      vim.api.nvim_feedkeys(vim.keycode("A<C-x><C-o><Esc>"), "xt", false)
      respond_all(case)
      vim.api.nvim_feedkeys(vim.keycode("A<C-x><C-o><Esc>"), "xt", false)
      assert.same({ case.expected }, vim.api.nvim_buf_get_lines(0, case.line, case.line + 1, false))
    end)
  end
end)
