describe("issue fields", function()
  local fields = require("github.features.issues.fields")
  local cache = require("github.core.cache")
  local target = { host = "github.com", owner = "a", repo = "r" }
  local calls, pending, old_run
  local function respond(index, data)
    pending[index]({ code = 0, stdout = vim.json.encode({ data = data }) })
  end
  before_each(function()
    calls, pending = {}, {}
    old_run = require("github.core.process").run
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin) }
      pending[#pending + 1] = cb
    end
    cache.clear()
  end)
  after_each(function()
    require("github.core.process").run = old_run
    cache.clear()
  end)
  it("paginates and caches assignable users", function()
    local values = {}
    fields.assignable_users(target, function(items, err)
      values[#values + 1] = items
      assert.is_nil(err)
    end)
    assert.equals(1, #calls)
    respond(1, {
      repository = {
        assignableUsers = {
          nodes = { { id = "U1", login = "alice" } },
          pageInfo = { hasNextPage = true, endCursor = "c1" },
        },
      },
    })
    assert.equals(2, #calls)
    assert.equals("c1", calls[2].body.variables.cursor)
    respond(2, {
      repository = {
        assignableUsers = {
          nodes = { { id = "U2", login = "bob" } },
          pageInfo = { hasNextPage = false },
        },
      },
    })
    assert.same({ { id = "U1", login = "alice" }, { id = "U2", login = "bob" } }, values[1])
    fields.assignable_users(target, function(items)
      values[#values + 1] = items
    end)
    assert.equals(2, #calls)
    assert.same(values[1], values[2])
  end)
  it("shares one request between concurrent candidate loads", function()
    local values = {}
    fields.assignable_users(target, function(items)
      values[#values + 1] = items
    end)
    fields.assignable_users(target, function(items)
      values[#values + 1] = items
    end)
    assert.equals(1, #calls)
    respond(1, {
      repository = {
        assignableUsers = { nodes = { { id = "U1", login = "alice" } }, pageInfo = { hasNextPage = false } },
      },
    })
    assert.equals(2, #values)
    assert.same(values[1], values[2])
  end)
  it("resolves assignees case-insensitively and rejects unknown logins", function()
    local result, err
    fields.resolve_assignees(target, { "Alice", "alice", "bob" }, function(value, failure)
      result, err = value, failure
    end)
    respond(1, {
      repository = {
        assignableUsers = {
          nodes = { { id = "U1", login = "alice" }, { id = "U2", login = "bob" } },
          pageInfo = { hasNextPage = false },
        },
      },
    })
    assert.is_nil(err)
    assert.same({
      ids = { "U1", "U2" },
      items = {
        { id = "U1", login = "alice" },
        { id = "U2", login = "bob" },
      },
    }, result)
    fields.resolve_assignees(target, { "carol" }, function(value, failure)
      result, err = value, failure
    end)
    assert.equals(1, #calls)
    assert.is_nil(result)
    assert.equals("Invalid or unavailable assignee: carol", err)
  end)
  it("resolves labels and projects and reports unknown names", function()
    local result, err
    fields.resolve_labels(target, { "bug" }, function(value, failure)
      result, err = value, failure
    end)
    respond(1, {
      repository = {
        labels = {
          nodes = { { id = "L1", name = "bug", color = "ff0000" } },
          pageInfo = { hasNextPage = false },
        },
      },
    })
    assert.is_nil(err)
    assert.same({ ids = { "L1" }, items = { { id = "L1", name = "bug", color = "ff0000" } } }, result)
    fields.resolve_labels(target, { "feature" }, function(value, failure)
      result, err = value, failure
    end)
    assert.equals(1, #calls)
    assert.is_nil(result)
    assert.equals("Invalid or unavailable label: feature", err)
    fields.resolve_projects(target, { "Roadmap" }, function(value, failure)
      result, err = value, failure
    end)
    respond(2, {
      repository = {
        projectsV2 = { nodes = { { id = "PVT_1", title = "Roadmap" } }, pageInfo = { hasNextPage = false } },
      },
    })
    assert.is_nil(err)
    assert.same({ ids = { "PVT_1" }, items = { { id = "PVT_1", title = "Roadmap" } } }, result)
    fields.resolve_projects(target, { "Missing" }, function(value, failure)
      result, err = value, failure
    end)
    assert.equals(2, #calls)
    assert.is_nil(result)
    assert.equals("Invalid or unavailable project: Missing", err)
  end)
  it("resolves a status field and option", function()
    local result, err
    fields.resolve_status(target, "PVT_1", "Status", "In progress", function(value, failure)
      result, err = value, failure
    end)
    respond(1, {
      node = {
        fields = {
          nodes = {
            {
              id = "PVTF_1",
              name = "Status",
              options = { { id = "OPT_TODO", name = "Todo" }, { id = "OPT_IN_PROGRESS", name = "In progress" } },
            },
          },
          pageInfo = { hasNextPage = false },
        },
      },
    })
    assert.is_nil(err)
    assert.same({
      field = {
        id = "PVTF_1",
        name = "Status",
        options = {
          { id = "OPT_TODO", name = "Todo" },
          { id = "OPT_IN_PROGRESS", name = "In progress" },
        },
      },
      option = { id = "OPT_IN_PROGRESS", name = "In progress" },
    }, result)
    fields.resolve_status(target, "PVT_1", "Status", "Nope", function(value, failure)
      result, err = value, failure
    end)
    assert.equals(1, #calls)
    assert.is_nil(result)
    assert.equals("Invalid Status value: Nope", err)
    fields.resolve_field(target, "PVT_1", "Unknown", function(value, failure)
      result, err = value, failure
    end)
    assert.equals(1, #calls)
    assert.is_nil(result)
    assert.equals("Project field not found: Unknown", err)
  end)
  it("updates the issue and validates the response", function()
    local ok, err
    fields.update_issue(target, { id = "I1", title = "New" }, function(value, failure)
      ok, err = value, failure
    end)
    assert.equals("updateIssue", calls[1].body.query:match("updateIssue"))
    assert.same({ id = "I1", title = "New" }, calls[1].body.variables.input)
    respond(1, { updateIssue = { issue = { id = "I1" } } })
    assert.is_true(ok)
    assert.is_nil(err)
    fields.update_issue(target, { id = "I1" }, function(value, failure)
      ok, err = value, failure
    end)
    respond(2, { updateIssue = { issue = { id = "OTHER" } } })
    assert.is_nil(ok)
    assert.equals("invalid update response", err)
  end)
  it("runs project item mutations and validates the responses", function()
    local value, err
    fields.add_project_item(target, "PVT_1", "I1", function(item_id, failure)
      value, err = item_id, failure
    end)
    assert.same({ projectId = "PVT_1", contentId = "I1" }, calls[1].body.variables)
    respond(1, { addProjectV2ItemById = { item = { id = "PVTI_1" } } })
    assert.equals("PVTI_1", value)
    assert.is_nil(err)
    fields.delete_project_item(target, "PVT_1", "PVTI_1", function(ok, failure)
      value, err = ok, failure
    end)
    assert.same({ projectId = "PVT_1", itemId = "PVTI_1" }, calls[2].body.variables)
    respond(2, { deleteProjectV2Item = { deletedItemId = "PVTI_1" } })
    assert.is_true(value)
    assert.is_nil(err)
    fields.update_project_field(target, "PVT_1", "PVTI_1", "PVTF_1", "OPT_1", function(ok, failure)
      value, err = ok, failure
    end)
    assert.same({
      projectId = "PVT_1",
      itemId = "PVTI_1",
      fieldId = "PVTF_1",
      value = { singleSelectOptionId = "OPT_1" },
    }, calls[3].body.variables)
    respond(3, { updateProjectV2ItemFieldValue = { projectV2Item = { id = "PVTI_1" } } })
    assert.is_true(value)
    assert.is_nil(err)
    fields.clear_project_field(target, "PVT_1", "PVTI_1", "PVTF_1", function(ok, failure)
      value, err = ok, failure
    end)
    assert.same({ projectId = "PVT_1", itemId = "PVTI_1", fieldId = "PVTF_1" }, calls[4].body.variables)
    respond(4, { clearProjectV2ItemFieldValue = { projectV2Item = { id = "PVTI_1" } } })
    assert.is_true(value)
    assert.is_nil(err)
    fields.add_project_item(target, "PVT_1", "I1", function(item_id, failure)
      value, err = item_id, failure
    end)
    respond(5, { addProjectV2ItemById = { item = { id = "" } } })
    assert.is_nil(value)
    assert.equals("invalid add response", err)
  end)
end)
