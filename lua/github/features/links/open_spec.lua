local pending, opened, notices, old_run, old_notify
local function issue(n)
  return {
    id = "I" .. n,
    number = n,
    title = "title " .. n,
    state = "OPEN",
    body = "",
    url = "https://github.com/a/r/issues/" .. n,
    repository = { name = "r", owner = { login = "a" } },
    comments = { totalCount = 0 },
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
    assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
end
local function comment(n)
  return {
    id = n,
    body = "body",
    user = { login = "alice" },
    html_url = "https://github.com/a/r/issues/7#issuecomment-" .. n,
  }
end
local function key(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
end
local function respond(value)
  pending[1]({ code = 0, stdout = vim.json.encode(value) })
end
local function setup_list(kind, items)
  if kind == "issue" then
    vim.cmd("edit github://a/r/issues")
    respond({ data = { search = { nodes = items } } })
  else
    vim.cmd("edit github://a/r/issues/7/comments")
    respond(items)
  end
end
describe("browser opening from lists", function()
  before_each(function()
    pending, opened, notices = {}, {}, {}
    old_run = require("github.core.process").run
    old_notify = vim.notify
    require("github.core.process").run = function(argv, _, callback)
      if argv[1] == "gh" then
        pending[#pending + 1] = callback
      else
        opened[#opened + 1] = { argv = argv, callback = callback }
      end
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run = old_run
    vim.notify = old_notify
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
    package.loaded["github.features.comments.list"] = nil
  end)
  for _, kind in ipairs({ "issue", "comment" }) do
    it("opens the current " .. kind .. " URL when no rows are selected", function()
      setup_list(kind, kind == "issue" and { issue(1), issue(2) } or { comment(1), comment(2) })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      key("<C-o>")
      local expected = kind == "issue" and "https://github.com/a/r/issues/2"
        or "https://github.com/a/r/issues/7#issuecomment-2"
      assert.equals(1, #opened)
      assert.equals(expected, opened[1].argv[#opened[1].argv])
      assert.equals(1, #pending)
    end)
    it("opens selected " .. kind .. " URLs in list order and freezes the targets", function()
      setup_list(kind, kind == "issue" and { issue(1), issue(2), issue(3) } or { comment(1), comment(2), comment(3) })
      key("<C-j>")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      key("<C-k>")
      key("<C-o>")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.equals(1, #opened)
      opened[1].callback({ code = 0, stderr = "" })
      assert.equals(2, #opened)
      local prefix = kind == "issue" and "https://github.com/a/r/issues/"
        or "https://github.com/a/r/issues/7#issuecomment-"
      assert.same(
        { prefix .. "1", prefix .. "3" },
        { opened[1].argv[#opened[1].argv], opened[2].argv[#opened[2].argv] }
      )
      assert.equals(1, #pending)
    end)
    it("reports no target for an empty " .. kind .. " list", function()
      setup_list(kind, {})
      key("<C-o>")
      assert.same({ "No URL selected" }, notices)
      assert.same({}, opened)
    end)
  end
  it("reports each failed URL and reason while continuing the remaining selected URLs", function()
    setup_list("issue", { issue(1), issue(2) })
    key("<C-j>")
    key("<C-j>")
    key("<C-o>")
    opened[1].callback({ code = 1, stderr = "" })
    opened[2].callback(nil, "process failed to start")
    assert.same({
      "Failed to open https://github.com/a/r/issues/1: browser exited with code 1",
      "Failed to open https://github.com/a/r/issues/2: process failed to start",
    }, notices)
    assert.equals(2, #opened)
  end)
  it("accepts a created issue URL without querying GitHub or building a shell command", function()
    local url = "https://github.com/a/r/issues/7?quoted='$(echo nope)'"
    require("github.features.links.open").open({ url })
    assert.equals(1, #opened)
    assert.equals(url, opened[1].argv[#opened[1].argv])
    assert.same({}, pending)
  end)
  it("reports a missing URL and continues with the remaining valid target", function()
    local first = issue(1)
    first.url = nil
    setup_list("issue", { first, issue(2) })
    key("<C-j>")
    key("<C-j>")
    key("<C-o>")
    assert.same({ "Failed to open : invalid URL" }, notices)
    assert.equals(1, #opened)
    assert.equals("https://github.com/a/r/issues/2", opened[1].argv[#opened[1].argv])
  end)
end)
