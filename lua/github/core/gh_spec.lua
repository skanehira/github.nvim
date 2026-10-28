describe("GitHub API adapter", function()
  it("passes JSON and arguments without shell interpretation", function()
    local gh = require("github.core.gh")
    local captured, result
    local adapter = gh.new(function(argv, opts, callback)
      captured = { argv = argv, opts = opts }
      callback({ code = 0, signal = 0, stdout = '{"data":{"ok":true}}', stderr = "" })
    end)
    adapter.graphql(
      { host = "github.com", owner = "owner", repo = "repo" },
      "mutation($body:String!){x}",
      { body = '日本語\n"quoted"' },
      function(value)
        result = value
      end
    )
    assert.same({ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }, captured.argv)
    assert.same(
      { query = "mutation($body:String!){x}", variables = { body = '日本語\n"quoted"' } },
      vim.json.decode(captured.opts.stdin)
    )
    assert.same({ data = { ok = true } }, result)
  end)

  it("reports process failure, invalid JSON and GraphQL errors for the target", function()
    local gh = require("github.core.gh")
    local responses = {
      { { code = 1, signal = 0, stdout = "", stderr = "secret" }, "GitHub request failed (exit 1)" },
      { { code = 0, signal = 0, stdout = "invalid", stderr = "" }, "invalid JSON response" },
      { { code = 0, signal = 0, stdout = '{"errors":[{"message":"x"}]}', stderr = "" }, "GraphQL errors returned" },
    }
    for _, pair in ipairs(responses) do
      local failure
      local adapter = gh.new(function(_, _, cb)
        cb(pair[1])
      end)
      adapter.graphql({ host = "github.com", owner = "o", repo = "r" }, "query {x}", {}, function(_, err)
        failure = err
      end)
      assert.same({ target = "github.com/o/r", reason = pair[2] }, failure)
    end
  end)

  it("rejects repeated pagination cursors", function()
    local gh = require("github.core.gh")
    local calls, error_result = 0
    gh.paginate(function(cursor, cb)
      calls = calls + 1
      cb({ items = { cursor or "first" }, pageInfo = { hasNextPage = true, endCursor = "same" } })
    end, function(_, err)
      error_result = err
    end)
    assert.equals(2, calls)
    assert.equals("pagination cursor repeated", error_result)
  end)
end)

describe("REST and pagination", function()
  it("sends explicit method, endpoint and JSON input", function()
    local captured, actual
    local gh = require("github.core.gh").new(function(argv, opts, cb)
      captured = { argv = argv, body = vim.json.decode(opts.stdin) }
      cb({ code = 0, stdout = '{"id":7}' })
    end)
    gh.rest(
      { host = "github.com", owner = "o", repo = "r" },
      "POST",
      "repos/o/r/issues",
      { body = '引用\n"x"' },
      function(value)
        actual = value
      end
    )
    assert.same({
      argv = { "gh", "api", "--hostname", "github.com", "--method", "POST", "repos/o/r/issues", "--input", "-" },
      body = { body = '引用\n"x"' },
    }, captured)
    assert.same({ id = 7 }, actual)
  end)
  it("returns accumulated pages only after the final cursor", function()
    local actual
    require("github.core.gh").paginate(function(cursor, cb)
      if cursor == nil then
        cb({ items = { "a" }, pageInfo = { hasNextPage = true, endCursor = "next" } })
      else
        cb({ items = { "b" }, pageInfo = { hasNextPage = false } })
      end
    end, function(items)
      actual = items
    end)
    assert.same({ "a", "b" }, actual)
  end)
end)

describe("pagination response validation", function()
  it("rejects incomplete and malformed pages without exposing partial results", function()
    local invalid = {
      {},
      { items = {}, pageInfo = {} },
      { items = { a = 1 }, pageInfo = { hasNextPage = false } },
      { items = {}, pageInfo = { hasNextPage = "false" } },
      { items = {}, pageInfo = { hasNextPage = true, endCursor = 123 } },
      { items = {}, pageInfo = { hasNextPage = true, endCursor = "" } },
    }
    for _, page in ipairs(invalid) do
      local count, value, failure = 0
      require("github.core.gh").paginate(function(cursor, cb)
        if not cursor then
          cb({ items = { "partial" }, pageInfo = { hasNextPage = true, endCursor = "next" } })
        else
          cb(page)
        end
      end, function(result, err)
        count, value, failure = count + 1, result, err
      end)
      assert.equals(1, count)
      assert.is_nil(value)
      assert.is_string(failure)
    end
  end)
end)
