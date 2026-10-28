local calls, callbacks, messages, old_run, old_notify, old_input
local function item(n, id)
  return {
    id = id or ("ID" .. n),
    number = n,
    title = "Title " .. n,
    state = "OPEN",
    body = "",
    repository = { name = "r", owner = { login = "a" } },
    comments = { totalCount = 0 },
    assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
end
local function search(i, nodes)
  callbacks[i]({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = nodes } } }) })
end
local function success(i)
  callbacks[i]({
    code = 0,
    stdout = vim.json.encode({
      data = { updateIssue = { issue = { id = calls[i].body.variables.id, state = calls[i].body.variables.state } } },
    }),
  })
end
local function key(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
end
describe("issue state changes", function()
  before_each(function()
    calls, callbacks, messages = {}, {}, {}
    old_run, old_notify, old_input = require("github.core.process").run, vim.notify, vim.ui.input
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin) }
      callbacks[#callbacks + 1] = cb
    end
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run, vim.notify, vim.ui.input = old_run, old_notify, old_input
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
  end)
  it("changes the cursor issue using ghc and gho and refreshes the last successful condition", function()
    vim.cmd("edit github://a/r/issues")
    search(1, { item(1), item(2) })
    vim.ui.input = function(_, cb)
      cb("state:closed")
    end
    vim.cmd("normal ghs")
    search(2, { item(1), item(2) })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal ghc")
    assert.equals("ID2", calls[3].body.variables.id)
    assert.equals("CLOSED", calls[3].body.variables.state)
    success(3)
    assert.equals("GitHub a/r #2: success (CLOSED)", messages[1])
    assert.equals("repo:a/r type:issue state:closed", calls[4].body.variables.query)
    search(4, { item(1) })
    vim.cmd("normal gho")
    assert.equals("ID1", calls[5].body.variables.id)
    assert.equals("OPEN", calls[5].body.variables.state)
    success(5)
    search(6, { item(1) })
  end)
  it("freezes selected targets and reports mixed outcomes and refresh failure independently", function()
    vim.cmd("edit github://a/r/issues")
    search(1, { item(1), item(2), item(3) })
    key("<C-j>")
    key("<C-j>")
    vim.cmd("normal ghc")
    assert.equals("ID1", calls[2].body.variables.id)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    success(2)
    assert.equals("ID2", calls[3].body.variables.id)
    callbacks[3]({ code = 0, stdout = vim.json.encode({ errors = { { message = "denied" } } }) })
    assert.equals("GitHub a/r #1: success (CLOSED)", messages[1])
    assert.equals("GitHub a/r #2: failed: GraphQL errors returned", messages[2])
    assert.equals(4, #calls)
    assert.equals("repo:a/r type:issue state:open", calls[4].body.variables.query)
    assert.equals(
      "#1 [OPEN] Title 1 | assignees:  | labels:  | comments: 0",
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
    callbacks[4]({ code = 1, stdout = "" })
    assert.equals("GitHub a/r: GitHub request failed (exit 1)", messages[3])
  end)
  it("reports no target and missing ids without mutation", function()
    vim.cmd("edit github://a/r/issues")
    search(1, {})
    vim.cmd("normal ghc")
    assert.equals(1, #calls)
    assert.equals("No issue selected", messages[1])
    require("github.features.issues.list").search(vim.api.nvim_get_current_buf(), "state:open")
    local missing = item(4)
    missing.id = vim.NIL
    search(2, { missing })
    vim.cmd("normal ghc")
    assert.equals("GitHub a/r #4: missing issue ID", messages[2])
    assert.equals("repo:a/r type:issue state:open", calls[3].body.variables.query)
  end)
  it("reports unknown results without retry and does not recreate a closed list", function()
    vim.cmd("edit github://a/r/issues")
    search(1, { item(1) })
    vim.cmd("normal ghc")
    vim.cmd("bwipeout!")
    vim.cmd("enew")
    callbacks[2]({ code = 1, stdout = "" })
    assert.equals("GitHub a/r #1: unknown: GitHub request failed (exit 1)", messages[1])
    assert.equals(2, #calls)
  end)
  it(
    "skips only the item without an ID and preserves selected targets despite changes to cursor and selection",
    function()
      vim.cmd("edit github://a/r/issues")
      local missing = item(2)
      missing.id = vim.NIL
      search(1, { item(1), missing, item(3) })
      key("<C-j>")
      key("<C-j>")
      key("<C-j>")
      vim.cmd("normal ghc")
      assert.equals("ID1", calls[2].body.variables.id)
      key("<C-k>")
      success(2)
      assert.equals("GitHub a/r #2: missing issue ID", messages[2])
      assert.equals("ID3", calls[3].body.variables.id)
      success(3)
      assert.equals("GitHub a/r #3: success (CLOSED)", messages[3])
      assert.equals(4, #calls)
      assert.equals("repo:a/r type:issue state:open", calls[4].body.variables.query)
    end
  )
end)
