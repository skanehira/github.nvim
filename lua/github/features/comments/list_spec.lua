local calls, pending, notices, old_run, old_notify
local function comment(id, body, user)
  return {
    id = id,
    body = body,
    user = user == false and vim.NIL or { login = user or "alice" },
    html_url = "https://github.com/a/r/issues/7#issuecomment-" .. id,
  }
end
local function respond(i, value)
  pending[i]({ code = 0, stdout = vim.json.encode(value) })
end
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end
local function key(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
end
local function issue()
  return {
    id = "I7",
    number = 7,
    title = "hello",
    body = "issue body",
    state = "OPEN",
    url = "https://github.com/a/r/issues/7",
    repository = { name = "r", owner = { login = "a" } },
    comments = { totalCount = 1 },
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
    assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
end
describe("comment list", function()
  before_each(function()
    calls, pending, notices = {}, {}, {}
    old_run = require("github.core.process").run
    old_notify = vim.notify
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, opts = opts }
      pending[#pending + 1] = cb
    end
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run = old_run
    vim.notify = old_notify
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only!")
    package.loaded["github.features.comments.list"] = nil
    package.loaded["github.features.issues.list"] = nil
  end)
  it("opens the URI and shows at most 100 comments, deleted users and full preview", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    assert.same(
      { "gh", "api", "--hostname", "github.com", "--method", "GET", "repos/a/r/issues/7/comments?per_page=100" },
      calls[1].argv
    )
    local items = { comment(1, "first\nsecond"), comment(2, "\nempty first", false) }
    for i = 3, 101 do
      items[i] = comment(i, "body " .. i, "u" .. i)
    end
    respond(1, items)
    local got = lines()
    assert.equals(100, #got)
    assert.equals("alice: first", got[1])
    assert.equals("[deleted]: ", got[2])
    assert.equals("u100: body 100", got[100])
    vim.cmd("normal K")
    assert.same({ "first", "second" }, lines())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(1, #calls)
  end)
  it("opens comments for the current issue using ghm", function()
    vim.cmd("edit github://a/r/issues")
    respond(1, { data = { search = { nodes = { issue() } } } })
    vim.cmd("normal ghm")
    assert.equals("github://a/r/issues/7/comments", vim.api.nvim_buf_get_name(0))
    assert.equals("repos/a/r/issues/7/comments?per_page=100", calls[2].argv[7])
    respond(2, { comment(2, "hello") })
    assert.same({ "alice: hello" }, lines())
  end)
  it("clears selection on refresh, shows empty results and keeps previous results on failure", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    respond(1, { comment(1, "one"), comment(2, "two") })
    key("<C-j>")
    assert.same({ "* alice: one", "alice: two" }, lines())
    vim.cmd("edit!")
    assert.same({ "alice: one", "alice: two" }, lines())
    pending[2]({ code = 1, stdout = "" })
    assert.same({ "alice: one", "alice: two" }, lines())
    assert.same({ "GitHub a/r: GitHub request failed (exit 1)" }, notices)
    vim.cmd("edit!")
    respond(3, {})
    assert.same({ "0 comments" }, lines())
    vim.cmd("edit!")
    pending[4]({ code = 1, stdout = "" })
    assert.same({ "0 comments" }, lines())
  end)
  it("toggles the current row backwards and previews the chosen full body", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    respond(1, { comment(1, "one"), comment(2, "\nsecond", false) })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    key("<C-k>")
    assert.same({ "alice: one", "* [deleted]: " }, lines())
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal K")
    assert.same({ "", "second" }, lines())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
  end)
  it("reports initial failure while retaining a failure display", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    pending[1]({ code = 1, stdout = "" })
    assert.same({ "Comment search failed" }, lines())
    assert.same({ "GitHub a/r: GitHub request failed (exit 1)" }, notices)
  end)
  it("ignores stale and closed-buffer responses", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    local buf = vim.api.nvim_get_current_buf()
    respond(1, { comment(1, "one") })
    vim.cmd("edit!")
    vim.cmd("edit!")
    respond(3, { comment(2, "new") })
    respond(2, { comment(3, "stale") })
    assert.same({ "alice: new" }, lines(buf))
    vim.cmd("edit!")
    vim.cmd("bwipeout!")
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unrelated" })
    respond(4, { comment(4, "late") })
    assert.same({ "unrelated" }, lines())
    assert.equals(false, vim.api.nvim_buf_is_valid(buf))
  end)
end)
