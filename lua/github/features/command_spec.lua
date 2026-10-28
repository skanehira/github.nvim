local old_run, old_notify, calls, pending, notices
local function item(number, state)
  return {
    __typename = "PullRequest",
    id = "PR" .. number,
    number = number,
    title = "変更 " .. number,
    state = state or "OPEN",
    body = "本文\r\n詳細",
    url = "https://github.com/a/r/pull/" .. number,
    repository = { name = "r", owner = { login = "a" } },
    comments = { totalCount = 3 },
    assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
end
local function respond(index, items)
  pending[index]({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = items } } }) })
end
local function keys(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
end

describe("GitHub list commands", function()
  before_each(function()
    calls, pending, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, opts = opts }
      if argv[1] == "git" then
        cb({ code = 0, stdout = argv[2] == "rev-parse" and "/checkout\n" or "git@github.com:a/r.git\n" })
      else
        pending[#pending + 1] = cb
      end
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run, vim.notify = old_run, old_notify
    vim.cmd("silent! %bwipeout!")
  end)
  for _, kind in ipairs({ "issues", "pulls" }) do
    it("opens " .. kind .. " from origin with the matching search type", function()
      vim.cmd("GitHub " .. kind)
      assert.equals("github://a/r/" .. kind, vim.api.nvim_buf_get_name(0))
      assert.same({ "git", "rev-parse", "--show-toplevel" }, calls[1].argv)
      assert.same({ "git", "remote", "get-url", "origin" }, calls[2].argv)
      assert.equals(vim.fn.getcwd(), calls[1].opts.cwd)
      local body = vim.json.decode(calls[3].opts.stdin)
      assert.equals("repo:a/r type:" .. (kind == "issues" and "issue" or "pr") .. " state:open", body.variables.query)
      respond(1, {})
      assert.same({ kind == "issues" and "0 issues" or "0 pull requests" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
    it("opens explicit " .. kind .. " without resolving a checkout", function()
      vim.cmd("GitHub " .. kind .. " a/r")
      assert.equals("github://a/r/" .. kind, vim.api.nvim_buf_get_name(0))
      assert.equals(1, #calls)
      assert.same({ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }, calls[1].argv)
      respond(1, {})
      assert.same({ kind == "issues" and "0 issues" or "0 pull requests" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
  end
  it("shows usage for unknown, missing, and malformed arguments without opening a buffer", function()
    local buf = vim.api.nvim_get_current_buf()
    for _, args in ipairs({ "", "unknown", "issues a", "pulls a/r/extra", "issues a/r extra" }) do
      vim.cmd("GitHub " .. args)
    end
    assert.same({
      "Usage: GitHub {issues|pulls} [owner/repo]",
      "Usage: GitHub {issues|pulls} [owner/repo]",
      "Usage: GitHub {issues|pulls} [owner/repo]",
      "Usage: GitHub {issues|pulls} [owner/repo]",
      "Usage: GitHub {issues|pulls} [owner/repo]",
    }, notices)
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.equals(0, #calls)
  end)
  it("reports origin resolution failure and retains the current buffer", function()
    local buf = vim.api.nvim_get_current_buf()
    require("github.core.process").run = function(_, _, cb)
      cb({ code = 1, stdout = "" })
    end
    vim.cmd("GitHub issues")
    assert.same(
      { "Cannot resolve repository in " .. vim.fn.getcwd() .. ": cannot determine local repository" },
      notices
    )
    assert.equals(buf, vim.api.nvim_get_current_buf())
  end)
  it("renders merged pulls with highlights and previews without offering Issue mutation mappings", function()
    vim.cmd("GitHub pulls a/r")
    respond(1, { item(7, "MERGED") })
    assert.same({ "  #7 変更 7 MERGED  ()  3" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals("gh-pulls", vim.bo.filetype)
    local spans = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().github, 0, -1, { details = true })
    assert.equals("gh_pull_merged", spans[2][4].hl_group)
    for _, key in ipairs({ "ghe", "ght", "ghc", "gho", "gha", "ghl", "ghn", "ghm" }) do
      assert.equals("", vim.fn.maparg(key, "n"))
    end
    local source = vim.api.nvim_get_current_win()
    keys("K")
    assert.equals(source, vim.api.nvim_get_current_win())
    assert.same({ "本文", "詳細" }, vim.api.nvim_buf_get_lines(vim.fn.bufnr("github:preview"), 0, -1, false))
  end)
  it("searches merged pulls from the search buffer and preserves the previous list on failure", function()
    vim.cmd("GitHub pulls a/r")
    local buf = vim.api.nvim_get_current_buf()
    respond(1, { item(1) })
    keys("ghs")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "is:merged" })
    keys("<CR>")
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.equals("repo:a/r type:pr is:merged", vim.json.decode(calls[2].opts.stdin).variables.query)
    respond(2, { item(2, "MERGED") })
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.cmd("edit!")
    pending[3]({ code = 1, stderr = "HTTP 403" })
    assert.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same({ "GitHub a/r: GitHub request failed (exit 1)" }, notices)
  end)
  it("rejects results from another repository or of the wrong type", function()
    vim.cmd("GitHub pulls a/r")
    local wrong = item(1)
    wrong.repository.name = "other"
    respond(1, { wrong })
    assert.same({ "Pull request search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("edit!")
    wrong = item(2)
    wrong.__typename = "Issue"
    respond(2, { wrong })
    assert.same({ "Pull request search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(2, #notices)
  end)
  it("keeps the source buffer when it changes during origin lookup", function()
    local finish
    require("github.core.process").run = function(_, _, cb)
      finish = cb
    end
    vim.cmd("GitHub issues")
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
    finish({ code = 0, stdout = "/checkout" })
    finish({ code = 0, stdout = "git@github.com:a/r.git" })
    assert.same({ "unsaved" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(0, #calls)
  end)
  it("ignores an earlier command resolving after a newer command", function()
    local delayed = {}
    require("github.core.process").run = function(_, _, cb)
      delayed[#delayed + 1] = cb
    end
    vim.cmd("GitHub issues")
    vim.cmd("GitHub pulls")
    delayed[2]({ code = 0, stdout = "/checkout" })
    delayed[3]({ code = 0, stdout = "git@github.com:a/r.git" })
    assert.equals("github://a/r/pulls", vim.api.nvim_buf_get_name(0))
    delayed[1]({ code = 0, stdout = "/checkout" })
    delayed[5]({ code = 0, stdout = "git@github.com:a/old.git" })
    assert.equals("github://a/r/pulls", vim.api.nvim_buf_get_name(0))
    delayed[4]({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = {} } } }) })
    assert.same({ "0 pull requests" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("copies selected PR URLs and opens the cursor PR in the browser", function()
    vim.cmd("GitHub pulls a/r")
    respond(1, { item(1), item(2) })
    local copy = require("github.features.links.copy")
    local saved, copied = copy.write
    copy.write = function(text)
      copied = text
      return true
    end
    keys("<C-j><C-k>ghy")
    copy.write = saved
    assert.equals("https://github.com/a/r/pull/1\nhttps://github.com/a/r/pull/2", copied)
    assert.same({ "Clipboard write requested for 2 URL(s); result unconfirmed" }, notices)
    keys("<C-o>")
    assert.equals("https://github.com/a/r/pull/1", calls[2].argv[#calls[2].argv])
    pending[2]({ code = 0, stdout = "" })
    assert.equals(2, #calls)
  end)
  it("completes PR label pages and ignores older search results", function()
    vim.cmd("GitHub pulls a/r")
    local first = item(1)
    first.labels = { nodes = { { name = "first" } }, pageInfo = { hasNextPage = true, endCursor = "p1" } }
    respond(1, { first })
    local body = vim.json.decode(calls[2].opts.stdin)
    assert.is_truthy(body.query:find("on PullRequest", 1, true))
    assert.same({ id = "PR1", cursor = "p1", assignees = false }, body.variables)
    pending[2]({
      code = 0,
      stdout = vim.json.encode({
        data = {
          node = {
            labels = {
              nodes = { { name = "second" } },
              pageInfo = { hasNextPage = false },
            },
          },
        },
      }),
    })
    assert.same({ "  #1 変更 1 OPEN  (first, second)  3" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local list, buf = require("github.features.issues.list"), vim.api.nvim_get_current_buf()
    list.search(buf, "state:closed")
    list.search(buf, "is:merged")
    respond(4, { item(4, "MERGED") })
    respond(3, { item(3, "CLOSED") })
    assert.same({ "  #4 変更 4 MERGED  ()  3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
  for _, explicit in ipairs({ false, true }) do
    it("finds the associated PR through GitHub related-pr " .. (explicit and "explicitly" or "from origin"), function()
      vim.cmd("GitHub related-pr " .. (explicit and "a/r " or "") .. "HEAD")
      local request = vim.json.decode(calls[explicit and 1 or 3].opts.stdin)
      assert.same({ owner = "a", repo = "r", commit = "HEAD" }, request.variables)
      pending[1]({
        code = 0,
        stdout = vim.json.encode({
          data = {
            repository = {
              object = {
                __typename = "Commit",
                associatedPullRequests = { nodes = { { url = "https://github.com/a/r/pull/7" } } },
              },
            },
          },
        }),
      })
      assert.same({ "https://github.com/a/r/pull/7" }, notices)
    end)
  end
  it("shows related-pr usage for invalid arguments", function()
    for _, args in ipairs({ "", "a/r HEAD extra", "bad HEAD" }) do
      vim.cmd("GitHub related-pr " .. args)
    end
    assert.same({
      "Usage: GitHub related-pr [owner/repo] commit",
      "Usage: GitHub related-pr [owner/repo] commit",
      "Usage: GitHub related-pr [owner/repo] commit",
    }, notices)
    assert.equals(0, #calls)
  end)
end)
