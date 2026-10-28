local calls, pending, old_run, old_input, old_notify, notices
local function issue(number, repo)
  return {
    id = "I" .. number,
    number = number,
    title = "Title " .. number,
    state = "OPEN",
    body = "Body " .. number,
    url = "https://github.com/a/" .. repo .. "/issues/" .. number,
    repository = { name = repo, owner = { login = "a" } },
    comments = { totalCount = 8 },
    assignees = { nodes = { { login = "alice" } }, pageInfo = { hasNextPage = false } },
    labels = { nodes = { { name = "bug" } }, pageInfo = { hasNextPage = false } },
  }
end
local function respond(index, nodes)
  pending[index]({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = nodes } } }) })
end
describe("issue list", function()
  before_each(function()
    calls, pending, notices = {}, {}, {}
    old_run = require("github.core.process").run
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin) }
      pending[#pending + 1] = cb
    end
    old_input, old_notify = require("github.core.view").search, vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.view").search, vim.notify = old_input, old_notify
    require("github.core.process").run = old_run
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
  end)
  it("aligns issue columns by display width and keeps them fixed when selecting rows", function()
    vim.cmd("edit github://a/r/issues")
    local short, long = issue(7, "r"), issue(123, "r")
    short.title, short.state = "日本語", "CLOSED"
    short.assignees.nodes, short.labels.nodes = {}, { { name = "修正" } }
    long.title = "long title"
    long.assignees.nodes, long.labels.nodes = { { login = "alice" }, { login = "bob" } }, {}
    long.comments.totalCount = 123
    respond(1, { short, long })
    local expected = {
      "  #7   日本語     CLOSED             (修正)  8",
      "  #123 long title OPEN   @alice @bob ()      123",
    }
    assert.same(expected, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-j>", true, false, true), "xt", false)
    expected[1] = "* " .. expected[1]:sub(3)
    assert.same(expected, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("highlights issue fields after multibyte titles and clears stale highlights on refresh", function()
    vim.cmd("edit github://a/r/issues")
    local first, second = issue(7, "r"), issue(123, "r")
    first.title, first.state = "日本語", "CLOSED"
    first.labels.nodes = { { name = "修正" } }
    respond(1, { first, second })
    local function highlights()
      local result, buf = {}, vim.api.nvim_get_current_buf()
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
      do
        local row, col, detail = mark[2], mark[3], mark[4]
        result[#result + 1] =
          { row, vim.api.nvim_buf_get_text(buf, row, col, row, detail.end_col, {})[1], detail.hl_group }
      end
      return result
    end
    local expected = {
      { 0, "#7", "gh_issue_number" },
      { 0, "CLOSED", "gh_issue_closed" },
      { 0, "@alice", "gh_issue_user" },
      { 0, "(修正)", "gh_issue_labels" },
      { 1, "#123", "gh_issue_number" },
      { 1, "OPEN", "gh_issue_open" },
      { 1, "@alice", "gh_issue_user" },
      { 1, "(bug)", "gh_issue_labels" },
    }
    assert.same(expected, highlights())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-j>", true, false, true), "xt", false)
    table.insert(expected, 1, { 0, "*", "gh_select" })
    assert.same(expected, highlights())
    vim.cmd("colorscheme default")
    assert.equals(0xb4be82, vim.api.nvim_get_hl(0, { name = "gh_issue_open", link = false }).fg)
    vim.cmd("edit!")
    respond(2, {})
    assert.same({}, highlights())
  end)
  for _, condition in ipairs({ "state:open", "state:closed" }) do
    local value = condition
    it("compares " .. condition .. " against a background result when confirming the search UI", function()
      vim.cmd("edit github://a/r/issues")
      local buf = vim.api.nvim_get_current_buf()
      respond(1, { issue(1, "r") })
      require("github.features.issues.list").search(buf, "state:closed")
      vim.cmd("normal ghs")
      assert.equals(vim.fn.bufnr("github:issues-search"), vim.api.nvim_get_current_buf())
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { value })
      respond(2, { issue(2, "r") })
      vim.cmd("stopinsert")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
      assert.equals(buf, vim.api.nvim_get_current_buf())
      assert.equals(value == "state:open" and 3 or 2, #calls)
      if value == "state:open" then
        assert.equals("repo:a/r type:issue state:open", calls[3].body.variables.query)
        respond(3, { issue(1, "r") })
      end
      assert.equals(value, require("github.features.issues.list").state(buf).condition)
    end)
  end
  it("opens URI and displays returned issue fields and preview", function()
    vim.cmd("edit github://a/r/issues")
    assert.equals("repo:a/r type:issue state:open", calls[1].body.variables.query)
    respond(1, { issue(1, "r") })
    assert.same({ "  #1 Title 1 OPEN @alice (bug)  8" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("normal K")
    assert.same({ "Body 1" }, vim.api.nvim_buf_get_lines(vim.fn.bufnr("github:preview"), 0, -1, false))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
  end)
  it("searches, clears selection, rejects foreign results, reloads last success and shows an empty result", function()
    vim.cmd("edit https://github.com/a/r/issues")
    respond(1, { issue(1, "r"), issue(2, "r") })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-j>", true, false, true), "xt", false)
    assert.equals("* #1 Title 1 OPEN @alice (bug)  8", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    require("github.core.view").search = function(_, _, cb)
      cb("state:closed")
    end
    vim.cmd("normal ghs")
    assert.equals("repo:a/r type:issue state:closed", calls[2].body.variables.query)
    assert.equals("  #1 Title 1 OPEN @alice (bug)  8", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    respond(2, { issue(3, "other") })
    assert.same({ "GitHub a/r: search returned an issue from another repository" }, notices)
    require("github.core.view").search = function(_, _, cb)
      cb("state:closed")
    end
    vim.cmd("normal ghs")
    respond(3, { issue(2, "r") })
    vim.cmd("edit!")
    assert.equals("repo:a/r type:issue state:closed", calls[4].body.variables.query)
    respond(4, {})
    assert.same({ "0 issues" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("preserves successful results on failure and cancellation and rejects stale and closed responses", function()
    vim.cmd("edit github://a/r/issues")
    local buf = vim.api.nvim_get_current_buf()
    respond(1, { issue(1, "r") })
    local previous = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    require("github.core.view").search = function(_, _, cb)
      cb(nil)
    end
    vim.cmd("normal ghs")
    assert.equals(1, #calls)
    require("github.core.view").search = function(_, _, cb)
      cb("first")
    end
    vim.cmd("normal ghs")
    require("github.core.view").search = function(_, _, cb)
      cb("second")
    end
    vim.cmd("normal ghs")
    respond(3, { issue(2, "r") })
    respond(2, { issue(3, "r") })
    assert.equals("  #2 Title 2 OPEN @alice (bug)  8", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    require("github.core.view").search = function(_, _, cb)
      cb("bad")
    end
    vim.cmd("normal ghs")
    pending[4]({ code = 1, stdout = "" })
    assert.same({ "GitHub a/r: GitHub request failed (exit 1)" }, notices)
    assert.equals("  #2 Title 2 OPEN @alice (bug)  8", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.equals("second", require("github.features.issues.list").state(buf).condition)
    assert.equals("  #1 Title 1 OPEN @alice (bug)  8", previous[1])
    require("github.core.view").search = function(_, _, cb)
      cb("late")
    end
    vim.cmd("normal ghs")
    vim.cmd("bwipeout!")
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "other buffer" })
    respond(5, { issue(4, "r") })
    assert.equals("other buffer", vim.api.nvim_get_current_line())
  end)
  it("keeps repository target after changing cwd and pages incomplete attributes", function()
    vim.cmd("edit github://a/r/issues")
    local item = issue(1, "r")
    item.labels.pageInfo = { hasNextPage = true, endCursor = "next" }
    respond(1, { item })
    assert.equals("next", calls[2].body.variables.cursor)
    pending[2]({
      code = 0,
      stdout = vim.json.encode({
        data = { node = { labels = { nodes = { { name = "feature" } }, pageInfo = { hasNextPage = false } } } },
      }),
    })
    assert.equals("  #1 Title 1 OPEN @alice (bug, feature)  8", vim.api.nvim_get_current_line())
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(vim.fn.tempname():match("(.+)/[^/]+$")))
    require("github.core.view").search = function(_, _, cb)
      cb("new")
    end
    vim.cmd("normal ghs")
    assert.equals("repo:a/r type:issue new", calls[3].body.variables.query)
    respond(3, { issue(2, "r") })
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    assert.equals("  #2 Title 2 OPEN @alice (bug)  8", vim.api.nvim_get_current_line())
  end)

  it("toggles selection at both edges and clears it on unsuccessful refresh", function()
    vim.cmd("edit github://a/r/issues")
    respond(1, { issue(1, "r"), issue(2, "r") })
    local key = function(k)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
    end
    key("<C-k>")
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    key("<C-k>")
    assert.equals("  #1 Title 1 OPEN @alice (bug)  8", vim.api.nvim_get_current_line())
    key("<C-j>")
    key("<C-j>")
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.equals("* #2 Title 2 OPEN @alice (bug)  8", vim.api.nvim_get_current_line())
    require("github.core.view").search = function(_, _, cb)
      cb("bad")
    end
    vim.cmd("normal ghs")
    pending[2]({ code = 1, stdout = "" })
    assert.equals("  #2 Title 2 OPEN @alice (bug)  8", vim.api.nvim_get_current_line())
    assert.equals("GitHub a/r: GitHub request failed (exit 1)", notices[1])
  end)
  it(
    "reports initial failure and rejects an incomplete attributes page without replacing successful results",
    function()
      vim.cmd("edit github://a/r/issues")
      pending[1]({ code = 1, stdout = "" })
      assert.same({ "Issue search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      require("github.core.view").search = function(_, _, cb)
        cb("state:open")
      end
      vim.cmd("normal ghs")
      respond(2, { issue(1, "r") })
      vim.cmd("normal ghs")
      local malformed = issue(2, "r")
      malformed.assignees.pageInfo = { hasNextPage = true, endCursor = "" }
      respond(3, { malformed })
      assert.equals("  #1 Title 1 OPEN @alice (bug)  8", vim.api.nvim_get_current_line())
      assert.equals("GitHub a/r: invalid pagination cursor", notices[2])
      assert.equals(3, #calls)
    end
  )
  it("requests at most 30 open issues and displays all returned results", function()
    vim.cmd("edit github://a/r/issues")
    assert.matches("search%(first:%s*30,%s*type:%s*ISSUE", calls[1].body.query)
    assert.equals("repo:a/r type:issue state:open", calls[1].body.variables.query)
    local nodes = {}
    for i = 1, 30 do
      nodes[i] = issue(i, "r")
    end
    respond(1, nodes)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.equals(30, #lines)
    assert.equals("  #1  Title 1  OPEN @alice (bug)  8", lines[1])
    assert.equals("  #30 Title 30 OPEN @alice (bug)  8", lines[30])
  end)

  it("shows initial failures and preserves successful results for invalid search pages", function()
    local cases = {
      {
        reason = "search returned an issue from another repository",
        reply = function(n)
          respond(n, { issue(1, "other") })
        end,
      },
      {
        reason = "invalid labels connection",
        reply = function(n)
          local item = issue(1, "r")
          item.labels.pageInfo = {}
          respond(n, { item })
        end,
      },
      {
        reason = "invalid pagination cursor",
        reply = function(n)
          local item = issue(1, "r")
          item.labels.pageInfo = { hasNextPage = true, endCursor = "" }
          respond(n, { item })
        end,
      },
      {
        reason = "GitHub request failed (exit 1)",
        reply = function(n)
          local item = issue(1, "r")
          item.labels.pageInfo = { hasNextPage = true, endCursor = "next" }
          respond(n, { item })
          pending[n + 1]({ code = 1, stdout = "" })
        end,
      },
    }
    for _, case in ipairs(cases) do
      calls, pending, notices = {}, {}, {}
      vim.cmd("edit github://a/r/issues")
      case.reply(1)
      assert.same({ "Issue search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.equals("GitHub a/r: " .. case.reason, notices[1])
      require("github.core.view").search = function(_, _, cb)
        cb("state:open")
      end
      vim.cmd("normal ghs")
      respond(#calls, { issue(2, "r") })
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      require("github.core.view").search = function(_, _, cb)
        cb("state:closed")
      end
      vim.cmd("normal ghs")
      case.reply(#calls)
      assert.same(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.equals(
        "state:open",
        require("github.features.issues.list").state(vim.api.nvim_get_current_buf()).condition
      )
      assert.equals("GitHub a/r: " .. case.reason, notices[2])
      vim.cmd("bwipeout!")
    end
  end)
end)
