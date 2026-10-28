local old_run, old_notify, calls, pending, notices
local function connection(nodes, more, cursor)
  return { nodes = nodes, pageInfo = { hasNextPage = more or false, endCursor = cursor or vim.NIL } }
end
local function reply(i, data)
  pending[i]({ code = 0, stdout = vim.json.encode({ data = data }) })
end
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end
local function set_lines(buf, values)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, values)
end

describe("issue attributes", function()
  before_each(function()
    calls, pending, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    require("github.core.process").run = function(_, opts, cb)
      calls[#calls + 1] = vim.json.decode(opts.stdin)
      pending[#pending + 1] = cb
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run, vim.notify = old_run, old_notify
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.attributes"] = nil
    package.loaded["github.features.issues.list"] = nil
  end)
  it("opens the current issue attributes from both list mappings", function()
    vim.cmd("edit github://a/r/issues")
    reply(1, {
      search = {
        nodes = {
          {
            id = "I1",
            number = 12,
            title = "Issue",
            state = "OPEN",
            body = "",
            repository = { name = "r", owner = { login = "a" } },
            comments = { totalCount = 0 },
            assignees = connection({}),
            labels = connection({}),
          },
        },
      },
    })
    local list_buf = vim.api.nvim_get_current_buf()
    vim.cmd("normal gha")
    assert.equals("github://a/r/issues/12/assignees", vim.api.nvim_buf_get_name(0))
    reply(2, { repository = { issue = { id = "I1", assignees = connection({}) } } })
    vim.api.nvim_set_current_buf(list_buf)
    vim.cmd("normal ghl")
    assert.equals("github://a/r/issues/12/labels", vim.api.nvim_buf_get_name(0))
    reply(3, { repository = { issue = { id = "I1", labels = connection({}) } } })
  end)
  for _, kind in ipairs({ "assignees", "labels" }) do
    local field = kind == "assignees" and "login" or "name"
    local idsfield = kind == "assignees" and "assigneeIds" or "labelIds"
    local candidates = kind == "assignees" and "assignableUsers" or "labels"
    local input = kind == "assignees" and "alice" or "bug"
    local second = kind == "assignees" and "bob" or "feature"
    local function node(name, id)
      return { [field] = name, id = id }
    end
    local function current(index, nodes, more, cursor)
      reply(index, { repository = { issue = { id = "ISSUE", [kind] = connection(nodes, more, cursor) } } })
    end
    local function options(index, nodes, more, cursor)
      reply(index, { repository = { [candidates] = connection(nodes, more, cursor) } })
    end
    it("opens and fully loads " .. kind .. ", replaces and clears only that field", function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      assert.is_false(vim.bo[buf].modifiable)
      current(1, { node(input, "1") }, true, "next")
      assert.equals("next", calls[2].variables.cursor)
      current(2, { node(second, "2") })
      assert.same({ input, second }, lines(buf))
      assert.is_true(vim.bo[buf].modifiable)
      set_lines(buf, { second, "", second })
      vim.cmd("write")
      options(3, { node(input, "1") }, true, "next")
      options(4, { node(second, "2") })
      assert.same({ "2" }, calls[5].variables.input[idsfield])
      assert.is_nil(calls[5].variables.input[kind == "assignees" and "labelIds" or "assigneeIds"])
      reply(5, { updateIssue = { issue = { id = "ISSUE" } } })
      assert.is_false(vim.bo[buf].modified)
      set_lines(buf, {})
      vim.cmd("write")
      assert.same({}, calls[6].variables.input[idsfield])
      reply(6, { updateIssue = { issue = { id = "ISSUE" } } })
      assert.is_false(vim.bo[buf].modified)
    end)
    it("preserves invalid input and failed updates for " .. kind, function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      current(1, { node(input, "1") })
      set_lines(buf, { "unknown" })
      vim.cmd("write")
      options(2, { node(input, "1") })
      assert.equals(2, #calls)
      assert.same({ "unknown" }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
      assert.equals("GitHub a/r: Invalid or unavailable " .. kind .. ": unknown", notices[1])
      set_lines(buf, { input })
      vim.cmd("write")
      options(3, { node(input, "1") })
      pending[4]({ code = 1, stdout = "" })
      assert.same({ input }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
      assert.equals("GitHub a/r: GitHub request failed (exit 1)", notices[2])
    end)
    it("refuses to save an incomplete initial " .. kind .. " set", function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      current(1, { node(input, "1") }, true, "next")
      pending[2]({ code = 1, stdout = "" })
      assert.is_false(vim.bo[buf].modifiable)
      vim.cmd("write")
      assert.equals(2, #calls)
      assert.equals("GitHub a/r: GitHub request failed (exit 1)", notices[1])
    end)
    it("preserves a draft across failed reloading and rejects incomplete candidate pages for " .. kind, function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      current(1, { node(input, "1") })
      set_lines(buf, { second })
      require("github.features.issues.attributes").read(
        buf,
        require("github.core.uri").parse(vim.api.nvim_buf_get_name(buf))
      )
      assert.same({ second }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
      assert.equals(1, #calls)
      vim.cmd("write")
      options(2, { node(second, "2") }, true, "next")
      pending[3]({ code = 1, stdout = "" })
      assert.same({ second }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
      assert.equals(3, #calls)
    end)
    it("allows explicit discard and reload for " .. kind, function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      current(1, { node(input, "1") })
      set_lines(buf, { second })
      vim.cmd("edit!")
      assert.equals(2, #calls)
      current(2, { node(input, "1") })
      assert.same({ input }, lines(buf))
      assert.is_false(vim.bo[buf].modified)
    end)
    it("keeps edits after saving and suppresses concurrent writes for " .. kind, function()
      vim.cmd("edit github://a/r/issues/12/" .. kind)
      local buf = vim.api.nvim_get_current_buf()
      current(1, { node(input, "1") })
      set_lines(buf, { second })
      vim.cmd("write")
      options(2, { node(second, "2") })
      set_lines(buf, { second, input })
      vim.cmd("write")
      assert.equals(3, #calls)
      assert.equals("GitHub a/r: save already in progress", notices[1])
      reply(3, { updateIssue = { issue = { id = "ISSUE" } } })
      assert.same({ second, input }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
    end)
  end
end)
