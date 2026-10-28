local pending, copied, notices, old_run, old_notify, old_write
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
local function setup_list(kind, items)
  if kind == "issue" then
    vim.cmd("edit github://a/r/issues")
    pending[1]({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = items } } }) })
  else
    vim.cmd("edit github://a/r/issues/7/comments")
    pending[1]({ code = 0, stdout = vim.json.encode(items) })
  end
end
describe("copying URLs from lists", function()
  before_each(function()
    pending, copied, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    require("github.core.process").run = function(_, _, callback)
      pending[#pending + 1] = callback
    end
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg, level }
    end
    vim.cmd("runtime plugin/github.lua")
    local copy = require("github.features.links.copy")
    old_write = copy.write
    copy.write = function(text)
      copied[#copied + 1] = text
      return true
    end
  end)
  after_each(function()
    require("github.core.process").run = old_run
    require("github.features.links.copy").write = old_write
    vim.notify = old_notify
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
    package.loaded["github.features.comments.list"] = nil
  end)
  for _, kind in ipairs({ "issue", "comment" }) do
    local prefix = kind == "issue" and "https://github.com/a/r/issues/"
      or "https://github.com/a/r/issues/7#issuecomment-"
    local build = kind == "issue" and issue or comment
    it("copies the current " .. kind .. " URL with no selection", function()
      setup_list(kind, { build(1), build(2) })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      key("ghy")
      assert.same({ prefix .. "2" }, copied)
      assert.equals("Clipboard write requested for 1 URL(s); result unconfirmed", notices[1][1])
      assert.equals(1, #pending)
    end)
    it("copies selected " .. kind .. " URLs in list order without a final newline", function()
      setup_list(kind, { build(1), build(2), build(3) })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      key("<C-k>")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      key("<C-j>")
      key("ghy")
      assert.same({ prefix .. "1\n" .. prefix .. "3" }, copied)
      assert.equals("Clipboard write requested for 2 URL(s); result unconfirmed", notices[1][1])
    end)
    it("preserves the clipboard when the " .. kind .. " list is empty", function()
      setup_list(kind, {})
      key("ghy")
      assert.same({}, copied)
      assert.matches("[Nn]o", notices[1][1])
    end)
    it("reports provider failure without announcing success for " .. kind, function()
      setup_list(kind, { build(1) })
      require("github.features.links.copy").write = function()
        return nil, "provider unavailable"
      end
      key("ghy")
      assert.same({}, copied)
      assert.matches("provider unavailable", notices[1][1])
      assert.equals(vim.log.levels.ERROR, notices[1][2])
      assert.equals(1, #notices)
    end)
  end
  it("copies a created issue URL through the same entry point", function()
    local url = "https://github.com/a/r/issues/7"
    require("github.features.links.copy").copy({ url })
    assert.same({ url }, copied)
    assert.equals("Clipboard write requested for 1 URL(s); result unconfirmed", notices[1][1])
    assert.same({}, pending)
  end)
  it("does not modify the clipboard if a selected target lacks a URL", function()
    local first = issue(1)
    first.url = nil
    setup_list("issue", { first, issue(2) })
    key("<C-j>")
    key("<C-j>")
    key("ghy")
    assert.same({}, copied)
    assert.equals(vim.log.levels.ERROR, notices[1][2])
  end)
end)

describe("clipboard provider integration", function()
  it("reports an unavailable clipboard provider without a successful notification", function()
    local copy = require("github.features.links.copy")
    local old_available, saved_notify = copy.available, vim.notify
    local messages = {}
    copy.available = function()
      return false
    end
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
    copy.copy({ "https://github.com/a/r/issues/1" })
    assert.same({ { "Clipboard write failed: clipboard provider unavailable", vim.log.levels.ERROR } }, messages)
    copy.available, vim.notify = old_available, saved_notify
  end)
  it("requests the + register through a fake Neovim provider and reports unconfirmed completion", function()
    vim.cmd([[
      function! GithubTestCopy(lines, regtype) abort
        let g:github_test_clipboard = [a:lines, a:regtype]
      endfunction
      function! GithubTestPaste() abort
        return [['old'], 'v']
      endfunction
      let g:clipboard = {'name': 'github-test',
            \ 'copy': {'+': function('GithubTestCopy'), '*': function('GithubTestCopy')},
            \ 'paste': {'+': function('GithubTestPaste'), '*': function('GithubTestPaste')},
            \ 'cache_enabled': 0}
    ]])
    local saved_notify = vim.notify
    local messages = {}
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
    require("github.features.links.copy").copy({ "https://github.com/a/r/issues/1", "https://github.com/a/r/issues/2" })
    assert.same(
      { { "https://github.com/a/r/issues/1", "https://github.com/a/r/issues/2" }, "v" },
      vim.g.github_test_clipboard
    )
    assert.same({ { "Clipboard write requested for 2 URL(s); result unconfirmed", vim.log.levels.INFO } }, messages)
    vim.notify = saved_notify
  end)
end)
