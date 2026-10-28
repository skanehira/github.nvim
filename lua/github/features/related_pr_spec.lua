local calls, notices, cwd
local function run(argv, opts, callback)
  table.insert(calls, { argv = argv, opts = opts, callback = callback })
end
local function respond(index, value, code)
  calls[index].callback({
    code = code or 0,
    stdout = type(value) == "table" and vim.json.encode(value) or value,
    stderr = "",
  })
end
local function result(object)
  return { data = { repository = { object = object } } }
end
local function execute(args)
  vim.cmd("GhGetAssociatedPullRequest " .. args)
end

describe("associated pull request command", function()
  before_each(function()
    calls, notices, cwd = {}, {}, "/outside"
    if vim.fn.exists(":GhGetAssociatedPullRequest") == 2 then
      vim.api.nvim_del_user_command("GhGetAssociatedPullRequest")
    end
    vim.cmd("runtime plugin/github_related_pr.lua")
    assert.equals(2, vim.fn.exists(":GhGetAssociatedPullRequest"))
    require("github.features.related_pr").setup({
      run = run,
      cwd = function()
        return cwd
      end,
      notify = function(message)
        table.insert(notices, message)
      end,
    })
  end)

  it("uses explicit repository outside a checkout and displays the first PR URL", function()
    execute("alice project abc123")
    assert.equals(1, #calls)
    assert.same({ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }, calls[1].argv)
    local request = vim.json.decode(calls[1].opts.stdin)
    assert.same({ owner = "alice", repo = "project", commit = "abc123" }, request.variables)
    assert.matches("associatedPullRequests%(first:%s*1%)", request.query)
    respond(
      1,
      result({
        __typename = "Commit",
        associatedPullRequests = {
          nodes = {
            { url = "https://github.com/alice/project/pull/3" },
            { url = "https://github.com/alice/project/pull/4" },
          },
        },
      })
    )
    assert.equals("https://github.com/alice/project/pull/3", notices[1])
  end)

  it("resolves the origin at the operation cwd and retains it across asynchronous work", function()
    cwd = "/checkout-a"
    execute("abcd")
    cwd = "/checkout-b"
    assert.same({ "git", "rev-parse", "--show-toplevel" }, calls[1].argv)
    assert.equals("/checkout-a", calls[1].opts.cwd)
    respond(1, "/checkout-a\n")
    assert.equals("/checkout-a", calls[2].opts.cwd)
    respond(2, "git@github.com:org/repo.git\n")
    assert.equals("/checkout-a", calls[3].opts.cwd)
    assert.same({ owner = "org", repo = "repo", commit = "abcd" }, vim.json.decode(calls[3].opts.stdin).variables)
    respond(
      3,
      result({
        __typename = "Commit",
        associatedPullRequests = { nodes = { { url = "https://github.com/org/repo/pull/9" } } },
      })
    )
    assert.equals("https://github.com/org/repo/pull/9", notices[1])
  end)

  it("distinguishes missing commit objects, non-commit objects, and no associated PR", function()
    for _, object in ipairs({
      vim.NIL,
      { __typename = "Blob" },
      { __typename = "Commit", associatedPullRequests = { nodes = {} } },
    }) do
      execute("alice project abc")
      respond(#calls, result(object))
    end
    assert.matches("[Cc]ommit", notices[1])
    assert.matches("[Cc]ommit", notices[2])
    assert.matches("[Pp]ull [Rr]equest", notices[3])
    assert.not_equals(notices[1], notices[3])
  end)

  it("reports invalid arguments and missing commit without consulting git or GitHub", function()
    execute("")
    execute("alice project")
    execute("a b c d")
    assert.equals(0, #calls)
    assert.equals(3, #notices)
    for _, message in ipairs(notices) do
      assert.matches("[Uu]sage", message)
      assert.matches("commit", message)
    end
  end)

  it("reports git origin and network failures without displaying another result", function()
    execute("abcd")
    respond(1, "", 1)
    assert.matches("repository", notices[1])
    execute("abcd")
    respond(2, "/repo\n")
    respond(3, "git@gitlab.com:other/repo.git\n")
    assert.matches("github.com", notices[2])
    execute("alice project abcd")
    respond(4, "", 1)
    assert.matches("alice/project", notices[3])
    assert.matches("failed", notices[3])
    assert.equals(4, #calls)
  end)
  it("keeps simultaneous explicit repositories independent when responses arrive in reverse order", function()
    execute("alice first sha1")
    execute("bob second sha2")
    assert.same({ owner = "alice", repo = "first", commit = "sha1" }, vim.json.decode(calls[1].opts.stdin).variables)
    assert.same({ owner = "bob", repo = "second", commit = "sha2" }, vim.json.decode(calls[2].opts.stdin).variables)
    respond(
      2,
      result({
        __typename = "Commit",
        associatedPullRequests = { nodes = { { url = "https://github.com/bob/second/pull/2" } } },
      })
    )
    respond(
      1,
      result({
        __typename = "Commit",
        associatedPullRequests = { nodes = { { url = "https://github.com/alice/first/pull/1" } } },
      })
    )
    assert.same({ "https://github.com/bob/second/pull/2", "https://github.com/alice/first/pull/1" }, notices)
  end)

  it("reports GraphQL errors, inaccessible repositories and malformed response data", function()
    execute("alice project sha")
    respond(1, { errors = { { message = "denied" } } })
    execute("alice project sha")
    respond(2, { data = { repository = vim.NIL } })
    execute("alice project sha")
    respond(3, result({ __typename = "Commit", associatedPullRequests = vim.NIL }))
    assert.matches("GraphQL errors", notices[1])
    assert.matches("repository not found", notices[2])
    assert.matches("invalid associated", notices[3])
    for _, notice in ipairs(notices) do
      assert.matches("alice/project", notice)
    end
  end)

  it("rejects an invalid explicit repository without running a process", function()
    execute("alice bad!repo sha")
    assert.equals(0, #calls)
    assert.matches("Invalid repository", notices[1])
    assert.matches("owner repo commit", notices[1])
  end)
end)
