local api_module = require("github.features.projects.api")

local function new_api(client, projects)
  return api_module.new({
    client = client,
    projects = projects or { group_by = "Status", column_width = 36, max_items = 1000 },
  })
end

local function scripted(responses)
  local calls, index = {}, 0
  local function next_response()
    index = index + 1
    local response = responses[index]
    assert(response, "unexpected API call " .. index)
    return response
  end
  return {
    graphql = function(target, query, variables, callback)
      calls[#calls + 1] = { type = "graphql", target = target, query = query, variables = variables }
      local response = next_response()
      if response.failure then
        callback(nil, response.failure)
      else
        callback(response)
      end
    end,
    rest = function(target, method, endpoint, body, callback)
      calls[#calls + 1] = { type = "rest", target = target, method = method, endpoint = endpoint, body = body }
      local response = next_response()
      if response.failure then
        callback(nil, response.failure)
      else
        callback(response.data)
      end
    end,
  },
    calls
end

local function deferred()
  local calls, pending = {}, {}
  local client = {
    graphql = function(target, query, variables, callback)
      calls[#calls + 1] = { type = "graphql", target = target, query = query, variables = variables }
      pending[#pending + 1] = callback
    end,
    rest = function(target, method, endpoint, body, callback)
      calls[#calls + 1] = { type = "rest", target = target, method = method, endpoint = endpoint, body = body }
      pending[#pending + 1] = callback
    end,
  }
  return client, calls, pending
end

local function project_node(number, closed)
  return {
    id = "P" .. number,
    number = number,
    title = "Project " .. number,
    items = { totalCount = number * 2 },
    public = true,
    closed = closed or false,
    url = "https://github.com/users/alice/projects/" .. number,
  }
end

local function projects_page(nodes, has_next, cursor, total_count)
  return {
    data = {
      user = {
        projectsV2 = {
          totalCount = total_count or #nodes,
          pageInfo = { hasNextPage = has_next, endCursor = cursor or vim.NIL },
          nodes = nodes,
        },
      },
    },
  }
end

local function org_projects_page(nodes, has_next, cursor)
  return {
    data = {
      organization = {
        projectsV2 = {
          totalCount = #nodes,
          pageInfo = { hasNextPage = has_next, endCursor = cursor or vim.NIL },
          nodes = nodes,
        },
      },
    },
  }
end

local function field_node(id, name, data_type, options)
  return {
    __typename = data_type == "SINGLE_SELECT" and "ProjectV2SingleSelectField" or "ProjectV2Field",
    id = id,
    name = name,
    dataType = data_type,
    options = options or vim.NIL,
  }
end

local function field_model(id, name, data_type, options)
  return { id = id, name = name, dataType = data_type, options = options or {} }
end

local function detail_response(project, fields, views)
  return {
    data = {
      user = {
        projectV2 = {
          id = project.id,
          number = project.number,
          title = project.title,
          url = project.url,
          public = project.public,
          closed = project.closed,
          items = project.items,
          fields = { nodes = fields },
          views = { nodes = views },
        },
      },
    },
  }
end

local function issue_item(id, number, title)
  return {
    id = id,
    type = "ISSUE",
    isArchived = false,
    content = {
      __typename = "Issue",
      number = number,
      title = title,
      state = "OPEN",
      url = "https://github.com/alice/repo/issues/" .. number,
      repository = { nameWithOwner = "alice/repo" },
      labels = { totalCount = 0, nodes = {} },
      assignees = { totalCount = 0, nodes = {} },
      subIssuesSummary = { total = 0, completed = 0 },
      closedByPullRequestsReferences = { totalCount = 0, nodes = {} },
    },
    fieldValues = { nodes = {} },
  }
end

local function items_page(nodes, total, has_next, cursor)
  return {
    data = {
      user = {
        projectV2 = {
          items = {
            totalCount = total,
            pageInfo = { hasNextPage = has_next, endCursor = cursor or vim.NIL },
            nodes = nodes,
          },
        },
      },
    },
  }
end

describe("Projects API", function()
  describe("owner resolution", function()
    it("resolves the authenticated user with REST user for omitted and @me owners", function()
      local client, calls = scripted({
        { data = { login = "alice", type = "User" } },
        { data = { login = "alice", type = "User" } },
      })
      local api = new_api(client)
      local results = {}
      api.resolve_owner({ host = "github.com" }, function(result, err)
        results[1] = { result = result, err = err }
      end)
      api.resolve_owner({ host = "github.com", owner = "@me" }, function(result, err)
        results[2] = { result = result, err = err }
      end)
      assert.same({ host = "github.com", owner = "alice", type = "User" }, results[1].result)
      assert.is_nil(results[1].err)
      assert.same({ host = "github.com", owner = "alice", type = "User" }, results[2].result)
      assert.same({ type = "rest", target = { host = "github.com" }, method = "GET", endpoint = "user" }, calls[1])
      assert.same({ type = "rest", target = { host = "github.com" }, method = "GET", endpoint = "user" }, calls[2])
    end)

    it("resolves a specified owner with REST users/{login} and uses the returned login", function()
      local client, calls = scripted({ { data = { login = "some-org", type = "Organization" } } })
      local api = new_api(client)
      local result, err
      api.resolve_owner({ host = "github.com", owner = "Some-Org" }, function(value, failure)
        result, err = value, failure
      end)
      assert.same({ host = "github.com", owner = "some-org", type = "Organization" }, result)
      assert.is_nil(err)
      assert.same(
        { type = "rest", target = { host = "github.com" }, method = "GET", endpoint = "users/Some-Org" },
        calls[1]
      )
    end)

    it("rejects invalid owners without sending a request", function()
      local client, calls = scripted({})
      local api = new_api(client)
      for _, owner in ipairs({ "", " ", "a/b", "a_b", "a b", "a.b", "-alice", "alice-" }) do
        local result, err
        api.resolve_owner({ host = "github.com", owner = owner }, function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("validation", err.kind)
      end
      assert.equals(0, #calls)
    end)

    it("classifies owner lookup failures", function()
      local cases = {
        { failure = { reason = "GitHub request failed (exit 1)", status = 404 }, kind = "not_found" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 403 }, kind = "forbidden" },
        {
          failure = { reason = "gh is not authenticated; run gh auth login --hostname github.com" },
          kind = "auth",
        },
        { failure = { reason = "GitHub process failed to start" }, kind = "network" },
      }
      for _, case in ipairs(cases) do
        local client = scripted({ { failure = case.failure } })
        local api = new_api(client)
        local result, err
        api.resolve_owner({ host = "github.com" }, function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals(case.kind, err.kind)
        assert.is_string(err.reason)
      end
    end)
  end)

  describe("project list", function()
    it("pages projects, excludes closed projects and truncates at 100 open projects", function()
      local first, second = {}, {}
      for number = 1, 60 do
        first[#first + 1] = project_node(number)
      end
      for number = 61, 64 do
        first[#first + 1] = project_node(number, true)
      end
      for number = 65, 114 do
        second[#second + 1] = project_node(number)
      end
      local client, calls = scripted({
        projects_page(first, true, "cursor-1", 120),
        projects_page(second, false, nil, 120),
      })
      local api = new_api(client)
      local result, err
      api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.equals(2, #calls)
      assert.same({ owner = "alice", after = nil }, calls[1].variables)
      assert.same({ owner = "alice", after = "cursor-1" }, calls[2].variables)
      assert.is_truthy(calls[1].query:find("user(login: $owner)", 1, true))
      assert.is_falsy(calls[1].query:find("organization(login: $owner)", 1, true))
      assert.is_truthy(calls[1].query:find("projectsV2(first: 100", 1, true))
      assert.equals(100, #result.projects)
      assert.is_true(result.truncated)
      assert.equals(120, result.total_count)
      for _, project in ipairs(result.projects) do
        assert.is_false(project.closed)
      end
      assert.same({
        id = "P1",
        number = 1,
        title = "Project 1",
        item_count = 2,
        public = true,
        closed = false,
        url = "https://github.com/users/alice/projects/1",
      }, result.projects[1])
    end)

    it("stops after ten pages and reports truncation when more projects remain", function()
      local responses = {}
      for page = 1, 10 do
        responses[page] = projects_page({ project_node(page) }, true, "cursor-" .. page)
      end
      local client, calls = scripted(responses)
      local api = new_api(client)
      local result
      api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value)
        result = value
      end)
      assert.equals(10, #calls)
      assert.equals(10, #result.projects)
      assert.is_true(result.truncated)
    end)

    it("returns an empty list without error when no open projects exist", function()
      local client = scripted({ projects_page({ project_node(1, true) }, false) })
      local api = new_api(client)
      local result, err
      api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.same({ projects = {}, total_count = 1, truncated = false }, result)
    end)

    it("uses the organization query for an organization owner", function()
      local client, calls = scripted({ org_projects_page({ project_node(1) }, false) })
      local api = new_api(client)
      local result, err
      api.list_projects({ host = "github.com", owner = "acme", type = "Organization" }, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.is_truthy(calls[1].query:find("organization(login: $owner)", 1, true))
      assert.is_falsy(calls[1].query:find("user(login: $owner)", 1, true))
      assert.equals(1, #result.projects)
    end)

    it("reports a malformed project list response as unknown", function()
      local client = scripted({
        { data = { user = { projectsV2 = { totalCount = 1, pageInfo = { hasNextPage = false }, nodes = "bad" } } } },
      })
      local api = new_api(client)
      local result, err
      api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(result)
      assert.equals("unknown", err.kind)
    end)
  end)

  describe("project detail", function()
    local function project(number)
      return {
        id = "P" .. number,
        number = number,
        title = "Roadmap",
        url = "https://github.com/users/alice/projects/" .. number,
        public = false,
        closed = false,
        items = { totalCount = 12 },
      }
    end

    local status_options = {
      { id = "opt-todo", name = "Todo", color = "RED" },
      { id = "opt-done", name = "Done", color = "GREEN" },
    }

    it("resolves editable fields, views, the first view filter and the group field", function()
      local fields = {
        field_node("F1", "Status", "SINGLE_SELECT", status_options),
        field_node("F2", "Priority", "SINGLE_SELECT", { { id = "opt-high", name = "High", color = "ORANGE" } }),
        field_node("F3", "Notes", "TEXT"),
        field_node("F4", "Title", "TITLE"),
        field_node("F5", "Labels", "LABELS"),
        field_node("F6", "Estimate", "NUMBER"),
        field_node("F7", "Due", "DATE"),
      }
      local views = {
        { number = 2, name = "Later", layout = "TABLE_LAYOUT", filter = "is:open" },
        { number = 1, name = "Board", layout = "BOARD_LAYOUT", filter = vim.NIL },
      }
      local client, calls = scripted({ detail_response(project(7), fields, views) })
      local api = new_api(client)
      local result, err
      api.detail({ host = "github.com", owner = "alice", type = "User" }, 7, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.equals(1, #calls)
      assert.is_truthy(calls[1].query:find("projectV2(number: $number)", 1, true))
      assert.same({ owner = "alice", number = 7 }, calls[1].variables)
      assert.same({
        field_model("F1", "Status", "SINGLE_SELECT", status_options),
        field_model("F2", "Priority", "SINGLE_SELECT", { { id = "opt-high", name = "High", color = "ORANGE" } }),
        field_model("F3", "Notes", "TEXT"),
        field_model("F6", "Estimate", "NUMBER"),
        field_model("F7", "Due", "DATE"),
      }, result.fields)
      assert.same(result.fields[1], result.group_field)
      assert.same({
        { number = 1, name = "Board", layout = "BOARD_LAYOUT", filter = "" },
        { number = 2, name = "Later", layout = "TABLE_LAYOUT", filter = "is:open" },
      }, result.views)
      assert.same(result.views[1], result.view)
      assert.equals("", result.filter)
      assert.same({
        id = "P7",
        number = 7,
        title = "Roadmap",
        item_count = 12,
        public = false,
        closed = false,
        url = "https://github.com/users/alice/projects/7",
      }, result.project)
    end)

    it("falls back to the first single-select field when group_by does not match", function()
      local fields = {
        field_node("F1", "Notes", "TEXT"),
        field_node("F2", "Priority", "SINGLE_SELECT", { { id = "opt-high", name = "High", color = "ORANGE" } }),
        field_node("F3", "Status", "SINGLE_SELECT", status_options),
      }
      local client = scripted({ detail_response(project(1), fields, {}) })
      local api = new_api(client, { group_by = "Missing", column_width = 36, max_items = 1000 })
      local result
      api.detail({ host = "github.com", owner = "alice", type = "User" }, 1, function(value)
        result = value
      end)
      assert.equals("Priority", result.group_field.name)
      assert.equals("", result.filter)
      assert.is_nil(result.view)
    end)

    it("uses a single nil column when no single-select field exists", function()
      local client = scripted({
        detail_response(project(1), { field_node("F1", "Notes", "TEXT") }, {}),
      })
      local api = new_api(client)
      local result
      api.detail({ host = "github.com", owner = "alice", type = "User" }, 1, function(value)
        result = value
      end)
      assert.is_nil(result.group_field)
    end)

    it("reports a missing project as not_found", function()
      local client = scripted({ { data = { user = { projectV2 = vim.NIL } } } })
      local api = new_api(client)
      local result, err
      api.detail({ host = "github.com", owner = "alice", type = "User" }, 99, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(result)
      assert.equals("not_found", err.kind)
    end)
  end)

  describe("items", function()
    it("pages items and truncates at max_items while keeping the total count", function()
      local first, second = {}, {}
      for number = 1, 100 do
        first[#first + 1] = issue_item("I" .. number, number, "Issue " .. number)
      end
      for number = 101, 200 do
        second[#second + 1] = issue_item("I" .. number, number, "Issue " .. number)
      end
      local client, calls = scripted({
        items_page(first, 250, true, "cursor-1"),
        items_page(second, 250, false),
      })
      local api = new_api(client, { group_by = "Status", column_width = 36, max_items = 150 })
      local result, err
      api.items({ host = "github.com", owner = "alice", type = "User" }, 7, "assignee:@me", function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.equals(2, #calls)
      assert.same({ owner = "alice", number = 7, after = nil, filter = "assignee:@me" }, calls[1].variables)
      assert.same({ owner = "alice", number = 7, after = "cursor-1", filter = "assignee:@me" }, calls[2].variables)
      assert.is_truthy(calls[1].query:find("archivedStates: [NOT_ARCHIVED]", 1, true))
      assert.is_truthy(calls[1].query:find("orderBy: {field: POSITION, direction: ASC}", 1, true))
      assert.equals(150, #result.items)
      assert.equals(250, result.total_count)
      assert.is_true(result.truncated)
      assert.equals("I150", result.items[150].id)
    end)

    it("requests the filter and archived states and returns zero items as success", function()
      local client, calls = scripted({ items_page({}, 0, false) })
      local api = new_api(client)
      local result, err
      api.items({ host = "github.com", owner = "alice", type = "User" }, 7, "", function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.same({ owner = "alice", number = 7, after = nil, filter = "" }, calls[1].variables)
      assert.same({ items = {}, total_count = 0, truncated = false }, result)
    end)

    it("converts Issue, PullRequest, DraftIssue and REDACTED content and field values", function()
      local issue = {
        id = "I1",
        type = "ISSUE",
        isArchived = false,
        content = {
          __typename = "Issue",
          number = 7,
          title = "Fix bug",
          state = "OPEN",
          url = "https://github.com/alice/repo/issues/7",
          repository = { nameWithOwner = "alice/repo" },
          labels = {
            totalCount = 7,
            nodes = { { name = "bug", color = "FF0000" }, { name = "p1", color = "00FF00" } },
          },
          assignees = { totalCount = 4, nodes = { { login = "bob" }, { login = "carol" } } },
          subIssuesSummary = { total = 3, completed = 1 },
          closedByPullRequestsReferences = {
            totalCount = 2,
            nodes = { { number = 8, url = "https://github.com/alice/repo/pull/8" } },
          },
        },
        fieldValues = {
          nodes = {
            {
              __typename = "ProjectV2ItemFieldTextValue",
              text = "hello",
              field = { id = "F1", name = "Notes", dataType = "TEXT" },
            },
            {
              __typename = "ProjectV2ItemFieldNumberValue",
              number = 3.5,
              field = { id = "F2", name = "Estimate", dataType = "NUMBER" },
            },
            {
              __typename = "ProjectV2ItemFieldDateValue",
              date = "2026-01-31",
              field = { id = "F3", name = "Due", dataType = "DATE" },
            },
            {
              __typename = "ProjectV2ItemFieldSingleSelectValue",
              name = "Todo",
              optionId = "opt-todo",
              field = { id = "F4", name = "Status", dataType = "SINGLE_SELECT" },
            },
            {
              __typename = "ProjectV2ItemFieldLabelValue",
              field = { id = "F5", name = "Labels", dataType = "LABELS" },
            },
            {
              __typename = "ProjectV2ItemFieldTextValue",
              text = "ignored",
              field = { id = "F6", name = "Title", dataType = "TITLE" },
            },
          },
        },
      }
      local pull = {
        id = "I2",
        type = "PULL_REQUEST",
        isArchived = false,
        content = {
          __typename = "PullRequest",
          number = 9,
          title = "Add feature",
          state = "MERGED",
          url = "https://github.com/alice/repo/pull/9",
          repository = { nameWithOwner = "alice/repo" },
          labels = { totalCount = 1, nodes = { { name = "ready", color = "00FF00" } } },
          assignees = { totalCount = 0, nodes = {} },
        },
        fieldValues = { nodes = {} },
      }
      local draft = {
        id = "I3",
        type = "DRAFT_ISSUE",
        isArchived = false,
        content = { __typename = "DraftIssue", title = "Draft", body = "Body" },
        fieldValues = { nodes = {} },
      }
      local redacted = {
        id = "I4",
        type = "REDACTED",
        isArchived = false,
        content = vim.NIL,
        fieldValues = { nodes = {} },
      }
      local client = scripted({ items_page({ issue, pull, draft, redacted }, 4, false) })
      local api = new_api(client)
      local result, err
      api.items({ host = "github.com", owner = "alice", type = "User" }, 7, "", function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.same({
        id = "I1",
        type = "ISSUE",
        archived = false,
        content = {
          number = 7,
          title = "Fix bug",
          state = "OPEN",
          url = "https://github.com/alice/repo/issues/7",
          repository = "alice/repo",
          labels = {
            total_count = 7,
            nodes = { { name = "bug", color = "FF0000" }, { name = "p1", color = "00FF00" } },
          },
          assignees = { total_count = 4, nodes = { { login = "bob" }, { login = "carol" } } },
          sub_issues = { total = 3, completed = 1 },
          related_pulls = {
            total_count = 2,
            nodes = { { number = 8, url = "https://github.com/alice/repo/pull/8" } },
          },
        },
        values = {
          F1 = { kind = "text", value = "hello" },
          F2 = { kind = "number", value = 3.5 },
          F3 = { kind = "date", value = "2026-01-31" },
          F4 = { kind = "single_select", value = "opt-todo", option_id = "opt-todo", name = "Todo" },
        },
      }, result.items[1])
      assert.same({
        id = "I2",
        type = "PULL_REQUEST",
        archived = false,
        content = {
          number = 9,
          title = "Add feature",
          state = "MERGED",
          url = "https://github.com/alice/repo/pull/9",
          repository = "alice/repo",
          labels = { total_count = 1, nodes = { { name = "ready", color = "00FF00" } } },
          assignees = { total_count = 0, nodes = {} },
        },
        values = {},
      }, result.items[2])
      assert.same({
        id = "I3",
        type = "DRAFT_ISSUE",
        archived = false,
        content = { title = "Draft", body = "Body" },
        values = {},
      }, result.items[3])
      assert.same({ id = "I4", type = "REDACTED", archived = false, values = {} }, result.items[4])
    end)

    it("reports malformed item responses as unknown", function()
      local cases = {
        {
          data = {
            user = { projectV2 = { items = { totalCount = 1, pageInfo = { hasNextPage = false }, nodes = "bad" } } },
          },
        },
        {
          data = {
            user = {
              projectV2 = {
                items = { totalCount = 1, pageInfo = { hasNextPage = false }, nodes = { { type = "ISSUE" } } },
              },
            },
          },
        },
        {
          data = {
            user = { projectV2 = { items = { totalCount = 1, pageInfo = { hasNextPage = "no" }, nodes = {} } } },
          },
        },
      }
      for _, response in ipairs(cases) do
        local client = scripted({ response })
        local api = new_api(client)
        local result, err
        api.items({ host = "github.com", owner = "alice", type = "User" }, 7, "", function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("unknown", err.kind)
      end
    end)
  end)

  describe("field updates", function()
    local text_field = field_model("F1", "Notes", "TEXT")
    local number_field = field_model("F2", "Estimate", "NUMBER")
    local date_field = field_model("F3", "Due", "DATE")
    local select_field = field_model("F4", "Status", "SINGLE_SELECT", {
      { id = "opt-todo", name = "Todo", color = "RED" },
      { id = "opt-done", name = "Done", color = "GREEN" },
    })

    local function update_response(id)
      return { data = { updateProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
    end

    local function clear_response(id)
      return { data = { clearProjectV2ItemFieldValue = { projectV2Item = { id = id } } } }
    end

    it("sends TEXT, NUMBER, DATE and SINGLE_SELECT values and clears empty text", function()
      local client, calls = scripted({
        update_response("I1"),
        update_response("I1"),
        update_response("I1"),
        update_response("I1"),
        clear_response("I1"),
        clear_response("I1"),
      })
      local api = new_api(client)
      local results = {}
      local function collect(index)
        return function(value, err)
          results[index] = { value = value, err = err }
        end
      end
      api.update_field("P1", "I1", text_field, "hello", collect(1))
      api.update_field("P1", "I1", number_field, "3.5", collect(2))
      api.update_field("P1", "I1", date_field, "2026-01-31", collect(3))
      api.update_field("P1", "I1", select_field, "opt-done", collect(4))
      api.update_field("P1", "I1", text_field, "", collect(5))
      api.clear_field("P1", "I1", "F4", collect(6))
      assert.same({ projectId = "P1", itemId = "I1", fieldId = "F1", value = { text = "hello" } }, calls[1].variables)
      assert.same({ projectId = "P1", itemId = "I1", fieldId = "F2", value = { number = 3.5 } }, calls[2].variables)
      assert.same(
        { projectId = "P1", itemId = "I1", fieldId = "F3", value = { date = "2026-01-31" } },
        calls[3].variables
      )
      assert.same(
        { projectId = "P1", itemId = "I1", fieldId = "F4", value = { singleSelectOptionId = "opt-done" } },
        calls[4].variables
      )
      assert.same({ projectId = "P1", itemId = "I1", fieldId = "F1" }, calls[5].variables)
      assert.same({ projectId = "P1", itemId = "I1", fieldId = "F4" }, calls[6].variables)
      assert.is_truthy(calls[1].query:find("updateProjectV2ItemFieldValue", 1, true))
      assert.is_truthy(calls[5].query:find("clearProjectV2ItemFieldValue", 1, true))
      assert.same({ item_id = "I1", field_id = "F1", value = { kind = "text", value = "hello" } }, results[1].value)
      assert.same({ item_id = "I1", field_id = "F2", value = { kind = "number", value = 3.5 } }, results[2].value)
      assert.same(
        { item_id = "I1", field_id = "F3", value = { kind = "date", value = "2026-01-31" } },
        results[3].value
      )
      assert.same({
        item_id = "I1",
        field_id = "F4",
        value = { kind = "single_select", value = "opt-done", option_id = "opt-done", name = "Done" },
      }, results[4].value)
      assert.same({ item_id = "I1", field_id = "F1" }, results[5].value)
      assert.same({ item_id = "I1", field_id = "F4" }, results[6].value)
      for index = 1, 6 do
        assert.is_nil(results[index].err)
      end
    end)

    it("rejects invalid numbers, dates, option IDs and field types before sending", function()
      local client, calls = scripted({})
      local api = new_api(client)
      local invalid = {
        { number_field, "abc" },
        { number_field, "nan" },
        { number_field, "inf" },
        { number_field, "" },
        { number_field, nil },
        { number_field, 0 / 0 },
        { number_field, math.huge },
        { number_field, -math.huge },
        { date_field, "2026-02-29" },
        { date_field, "1900-02-29" },
        { date_field, "2026-04-31" },
        { date_field, "2026-13-01" },
        { date_field, "2026-00-01" },
        { date_field, "0000-01-01" },
        { date_field, "9999-12-32" },
        { date_field, "2026-1-1" },
        { date_field, "2026/01/01" },
        { date_field, "" },
        { date_field, nil },
        { select_field, "unknown-option" },
        { field_model("F9", "Iteration", "ITERATION"), "value" },
        { text_field, nil },
      }
      for _, case in ipairs(invalid) do
        local result, err
        api.update_field("P1", "I1", case[1], case[2], function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("validation", err.kind)
      end
      assert.equals(0, #calls)
    end)

    it("accepts leap days and date boundaries", function()
      local client, calls = scripted({
        update_response("I1"),
        update_response("I1"),
        update_response("I1"),
      })
      local api = new_api(client)
      local results = {}
      local function collect(index)
        return function(value)
          results[index] = value
        end
      end
      api.update_field("P1", "I1", date_field, "2024-02-29", collect(1))
      api.update_field("P1", "I1", date_field, "0001-01-01", collect(2))
      api.update_field("P1", "I1", date_field, "9999-12-31", collect(3))
      assert.equals(3, #calls)
      assert.same({ kind = "date", value = "2024-02-29" }, results[1].value)
      assert.same({ kind = "date", value = "0001-01-01" }, results[2].value)
      assert.same({ kind = "date", value = "9999-12-31" }, results[3].value)
    end)

    it("does not resend failed writes and does not report unknown results as success", function()
      local client, calls = scripted({
        { failure = { reason = "GitHub request failed (exit 1)", status = 500 } },
      })
      local api = new_api(client)
      local result, err
      api.update_field("P1", "I1", text_field, "hello", function(value, failure)
        result, err = value, failure
      end)
      assert.equals(1, #calls)
      assert.is_nil(result)
      assert.equals("unknown", err.kind)
    end)

    it("rejects mismatched mutation responses", function()
      local client = scripted({ update_response("I2") })
      local api = new_api(client)
      local result, err
      api.update_field("P1", "I1", text_field, "hello", function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(result)
      assert.equals("unknown", err.kind)
    end)
  end)

  describe("content resolution", function()
    it("resolves issue and pull request URLs and owner/repo#number", function()
      local client, calls = scripted({
        { data = { repository = { issueOrPullRequest = { __typename = "Issue", id = "I7" } } } },
        { data = { repository = { issueOrPullRequest = { __typename = "PullRequest", id = "PR9" } } } },
        { data = { repository = { issueOrPullRequest = { __typename = "PullRequest", id = "PR8" } } } },
        { data = { repository = { issueOrPullRequest = { __typename = "Issue", id = "I7" } } } },
      })
      local api = new_api(client)
      local results = {}
      local function collect(index)
        return function(value, err)
          results[index] = { value = value, err = err }
        end
      end
      api.resolve_content({ host = "github.com" }, "https://github.com/alice/repo/issues/7", collect(1))
      api.resolve_content({ host = "github.com" }, "https://github.com/alice/repo/pull/9", collect(2))
      api.resolve_content({ host = "github.com" }, "alice/repo#8", collect(3))
      api.resolve_content({ host = "github.com" }, "  https://github.com/alice/repo/issues/7/  ", collect(4))
      assert.same({ id = "I7", type = "Issue", owner = "alice", repo = "repo", number = 7 }, results[1].value)
      assert.same({ id = "PR9", type = "PullRequest", owner = "alice", repo = "repo", number = 9 }, results[2].value)
      assert.same({ id = "PR8", type = "PullRequest", owner = "alice", repo = "repo", number = 8 }, results[3].value)
      assert.same({ id = "I7", type = "Issue", owner = "alice", repo = "repo", number = 7 }, results[4].value)
      assert.same({ owner = "alice", repo = "repo", number = 7 }, calls[1].variables)
      assert.is_truthy(calls[1].query:find("issueOrPullRequest(number: $number)", 1, true))
      for index = 1, 4 do
        assert.is_nil(results[index].err)
      end
    end)

    it("rejects malformed content references without sending a request", function()
      local client, calls = scripted({})
      local api = new_api(client)
      local invalid = {
        "",
        "   ",
        "http://github.com/alice/repo/issues/7",
        "https://gitlab.com/alice/repo/issues/7",
        "https://www.github.com/alice/repo/issues/7",
        "https://github.com/alice/repo/issues/7?x=1",
        "https://github.com/alice/repo/issues/7#fragment",
        "https://github.com/alice/repo/issues/7/extra",
        "https://github.com/alice/repo/issues/0",
        "https://github.com/alice/repo/issues/-1",
        "alice/repo#0",
        "alice/repo#-1",
        "alice/repo#1.5",
        "alice_repo#1",
        "alice/repo# 1",
        "-alice/repo#1",
      }
      for _, reference in ipairs(invalid) do
        local result, err
        api.resolve_content({ host = "github.com" }, reference, function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("validation", err.kind)
      end
      assert.equals(0, #calls)
    end)

    it("reports an unresolved issue or pull request as not_found", function()
      local cases = {
        { data = { repository = vim.NIL } },
        { data = { repository = { issueOrPullRequest = vim.NIL } } },
        {
          failure = {
            reason = "GraphQL errors returned",
            errors = { "Could not resolve to a node with the global id of 'I7'" },
          },
        },
      }
      for _, response in ipairs(cases) do
        local client = scripted({ response })
        local api = new_api(client)
        local result, err
        api.resolve_content({ host = "github.com" }, "alice/repo#7", function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("not_found", err.kind)
      end
    end)

    it("fetches issue and pull request bodies through issueOrPullRequest", function()
      local client, calls = scripted({
        { data = { repository = { issueOrPullRequest = { __typename = "Issue", body = "Issue body" } } } },
        { data = { repository = { issueOrPullRequest = { __typename = "PullRequest", body = "PR body" } } } },
        { data = { repository = { issueOrPullRequest = vim.NIL } } },
      })
      local api = new_api(client)
      local results = {}
      local function collect(index)
        return function(value, err)
          results[index] = { value = value, err = err }
        end
      end
      api.fetch_body({ host = "github.com" }, "alice/repo", 7, collect(1))
      api.fetch_body({ host = "github.com" }, "alice/repo", 9, collect(2))
      api.fetch_body({ host = "github.com" }, "alice/repo", 99, collect(3))
      assert.same({ type = "Issue", body = "Issue body" }, results[1].value)
      assert.same({ type = "PullRequest", body = "PR body" }, results[2].value)
      assert.is_nil(results[3].value)
      assert.equals("not_found", results[3].err.kind)
      assert.same({ owner = "alice", repo = "repo", number = 7 }, calls[1].variables)
    end)
  end)

  describe("item mutations", function()
    it("adds an existing item idempotently and flags duplicates", function()
      local item = issue_item("I1", 7, "Fix bug")
      local client, calls = scripted({
        { data = { addProjectV2ItemById = { item = item } } },
        { data = { addProjectV2ItemById = { item = item } } },
      })
      local api = new_api(client)
      local results = {}
      local function collect(index)
        return function(value, err)
          results[index] = { value = value, err = err }
        end
      end
      api.add_item("P1", "I1", { I1 = true }, collect(1))
      api.add_item("P1", "I1", {}, collect(2))
      assert.same({ projectId = "P1", contentId = "I1" }, calls[1].variables)
      assert.is_truthy(calls[1].query:find("addProjectV2ItemById", 1, true))
      assert.is_true(results[1].value.duplicate)
      assert.is_false(results[2].value.duplicate)
      assert.same(item.id, results[1].value.item.id)
      assert.equals("ISSUE", results[1].value.item.type)
    end)

    it("reports a malformed add response as unknown", function()
      local client = scripted({ { data = { addProjectV2ItemById = { item = { type = "ISSUE" } } } } })
      local api = new_api(client)
      local result, err
      api.add_item("P1", "I1", {}, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(result)
      assert.equals("unknown", err.kind)
    end)

    it("adds a draft issue with a trimmed required title and optional body", function()
      local item = {
        id = "I5",
        type = "DRAFT_ISSUE",
        isArchived = false,
        content = { __typename = "DraftIssue", title = "Draft", body = "" },
        fieldValues = { nodes = {} },
      }
      local client, calls = scripted({ { data = { addProjectV2DraftIssue = { projectItem = item } } } })
      local api = new_api(client)
      local result, err
      api.add_draft("P1", "  Draft  ", nil, function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.same({ projectId = "P1", title = "Draft", body = "" }, calls[1].variables)
      assert.is_truthy(calls[1].query:find("addProjectV2DraftIssue", 1, true))
      assert.same("I5", result.item.id)
      assert.same({ title = "Draft", body = "" }, result.item.content)
    end)

    it("rejects blank draft titles without sending a request", function()
      local client, calls = scripted({})
      local api = new_api(client)
      for _, title in ipairs({ "", "   ", nil }) do
        local result, err
        api.add_draft("P1", title, "body", function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals("validation", err.kind)
      end
      assert.equals(0, #calls)
    end)

    it("deletes only the project item and returns the deleted item ID", function()
      local client, calls = scripted({ { data = { deleteProjectV2Item = { deletedItemId = "I1" } } } })
      local api = new_api(client)
      local result, err
      api.delete_item("P1", "I1", function(value, failure)
        result, err = value, failure
      end)
      assert.is_nil(err)
      assert.same({ projectId = "P1", itemId = "I1" }, calls[1].variables)
      assert.is_truthy(calls[1].query:find("deleteProjectV2Item", 1, true))
      assert.is_falsy(calls[1].query:find("deleteIssue", 1, true))
      assert.same({ item_id = "I1" }, result)
    end)

    it("does not treat a missing deleted item as success", function()
      local cases = {
        { data = { deleteProjectV2Item = { deletedItemId = vim.NIL } }, kind = "not_found" },
        { data = { deleteProjectV2Item = { deletedItemId = "I2" } }, kind = "unknown" },
        {
          failure = { reason = "GraphQL errors returned", errors = { "Could not resolve to a node" } },
          kind = "not_found",
        },
      }
      for _, response in ipairs(cases) do
        local client = scripted({ response })
        local api = new_api(client)
        local result, err
        api.delete_item("P1", "I1", function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals(response.kind, err.kind)
      end
    end)
  end)

  describe("error classification", function()
    it("classifies GraphQL errors and HTTP statuses without reporting success", function()
      local cases = {
        {
          failure = { reason = "gh is not installed; install GitHub CLI (https://cli.github.com/)" },
          kind = "auth",
        },
        {
          failure = { reason = "gh is not authenticated; run gh auth login --hostname github.com" },
          kind = "auth",
        },
        { failure = { reason = "GitHub process failed to start" }, kind = "network" },
        { failure = { reason = "GitHub request failed (exit 1)" }, kind = "unknown" },
        { failure = { reason = "invalid JSON response" }, kind = "unknown" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 401 }, kind = "auth" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 403 }, kind = "forbidden" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 404 }, kind = "not_found" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 422 }, kind = "validation" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 429 }, kind = "rate_limit" },
        { failure = { reason = "GitHub request failed (exit 1)", status = 500 }, kind = "unknown" },
        {
          failure = {
            reason = "GraphQL errors returned",
            errors = { "Could not resolve to a node with the global id of 'P1'" },
          },
          kind = "not_found",
          message = "Could not resolve",
        },
        {
          failure = { reason = "GraphQL errors returned", errors = { "A temporary conflict occurred" } },
          kind = "conflict",
          message = "temporary conflict",
        },
        {
          failure = {
            reason = "GraphQL errors returned",
            errors = { "Expected type ProjectV2FieldValue, found String." },
          },
          kind = "validation",
          message = "Expected type",
        },
        {
          failure = {
            reason = "GraphQL errors returned",
            errors = { "Your token has not been granted the required scopes to execute this query." },
          },
          kind = "auth",
          message = "scopes",
        },
        {
          failure = { reason = "GraphQL errors returned", errors = { "API rate limit exceeded for user" } },
          kind = "rate_limit",
          message = "rate limit",
        },
      }
      for _, case in ipairs(cases) do
        local client = scripted({ { failure = case.failure } })
        local api = new_api(client)
        local result, err
        api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value, failure)
          result, err = value, failure
        end)
        assert.is_nil(result)
        assert.equals(case.kind, err.kind)
        assert.is_string(err.reason)
        if case.message then
          assert.is_truthy(err.reason:lower():find(case.message:lower(), 1, true))
        end
      end
    end)

    it("delivers responses to their own callbacks without shared state", function()
      local client, calls, pending = deferred()
      local api = new_api(client)
      local results = {}
      api.list_projects({ host = "github.com", owner = "alice", type = "User" }, function(value, err)
        results.alice = { value = value, err = err }
      end)
      api.list_projects({ host = "github.com", owner = "acme", type = "Organization" }, function(value, err)
        results.acme = { value = value, err = err }
      end)
      assert.equals(2, #calls)
      pending[2](org_projects_page({ project_node(2) }, false))
      pending[1](projects_page({ project_node(1) }, false))
      assert.equals(1, results.alice.value.projects[1].number)
      assert.equals(2, results.acme.value.projects[1].number)
      assert.is_nil(results.alice.err)
      assert.is_nil(results.acme.err)
    end)
  end)
end)
