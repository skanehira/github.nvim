local old_choose
local old_columns
local calls, pending, notices, old_run, old_notify
local function response(index, data)
  pending[index]({ code = 0, stdout = vim.json.encode({ data = data }) })
end
local function header(buf)
  local namespace = vim.api.nvim_get_namespaces().github_issue_detail
  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local virtual = mark[4].virt_lines
    if virtual then
      local lines = {}
      for _, chunks in ipairs(virtual) do
        local text = ""
        for _, chunk in ipairs(chunks) do
          text = text .. chunk[1]
        end
        lines[#lines + 1] = text
      end
      return lines
    end
  end
  return nil
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
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin) }
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
    assert.same({ "日本語", "second" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals("markdown", vim.bo.filetype)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    vim.cmd("write")
    assert.same({ id = "I1", body = "" }, calls[2].body.variables.input)
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #1: body saved", notices[#notices])
  end)
  it("preserves pending edits, blocks duplicate writes, and retains content after failure", function()
    vim.cmd("edit github://a/r/issues/1")
    loaded(1)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    vim.cmd("write")
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "later" })
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #1: save already in progress", notices[#notices])
    response(2, { updateIssue = { issue = { id = "I1" } } })
    assert.is_true(vim.bo.modified)
    assert.same({ "draft", "later" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("write")
    pending[3]({ code = 1, stdout = "" })
    assert.is_true(vim.bo.modified)
    assert.same({ "draft", "later" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals("GitHub a/r #1: GitHub request failed (exit 1)", notices[#notices])
    assert.is_false(pcall(vim.cmd, "bdelete"))
    assert.same({ "draft", "later" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
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
    assert.same({ "body" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
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
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "作業中", "改行" })
    local buf = vim.api.nvim_get_current_buf()
    require("github.features.issues.edit").read(
      buf,
      { kind = "issue_edit", host = "github.com", owner = "a", repo = "r", issue_number = 1 }
    )
    assert.equals(1, #calls)
    assert.equals("GitHub a/r #1: unsaved changes retained", notices[#notices])
    assert.same({ "作業中", "改行" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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
  it("renders the issue header above the editable body", function()
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
                project = { title = "Roadmap" },
                fieldValues = { nodes = { { name = "In progress", field = { name = "Status" } } } },
              },
            },
          },
        },
      },
    })
    local text = table.concat(header(vim.api.nvim_get_current_buf()), "\n")
    assert.is_truthy(text:find("Title", 1, true))
    assert.is_truthy(text:find("● Open", 1, true))
    assert.is_truthy(text:find("#1", 1, true))
    assert.is_truthy(text:find("a/r", 1, true))
    assert.is_truthy(text:find("@alice", 1, true))
    assert.is_truthy(text:find("@bob", 1, true))
    assert.is_truthy(text:find("bug", 1, true))
    assert.is_truthy(text:find("help wanted", 1, true))
    assert.is_truthy(text:find("Roadmap", 1, true))
    assert.is_truthy(text:find("Status: In progress", 1, true))
    assert.same({ "body" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
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
    assert.same({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
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
    assert.same({ "body" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(0, #notices)
  end)
  it("wraps the header to the window width", function()
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
                project = { title = "A project with a long title" },
                fieldValues = { nodes = { { name = "In progress", field = { name = "Status" } } } },
              },
            },
          },
        },
      },
    })
    local lines = header(vim.api.nvim_get_current_buf())
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 40)
    end
  end)
end)
