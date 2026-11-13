local M = {}

local editable_types = { TEXT = true, NUMBER = true, DATE = true, SINGLE_SELECT = true }

local status_kinds = {
  [401] = "auth",
  [403] = "forbidden",
  [404] = "not_found",
  [422] = "validation",
  [429] = "rate_limit",
}

local item_fields = [[
id type isArchived
content {
  __typename
  ... on Issue {
    number title state url
    repository { nameWithOwner }
    labels(first: 5) { totalCount nodes { name color } }
    assignees(first: 3) { totalCount nodes { login } }
    subIssuesSummary { total completed }
    closedByPullRequestsReferences(first: 3) { totalCount nodes { number url } }
  }
  ... on PullRequest {
    number title state url
    repository { nameWithOwner }
    labels(first: 5) { totalCount nodes { name color } }
    assignees(first: 3) { totalCount nodes { login } }
  }
  ... on DraftIssue { title body }
}
fieldValues(first: 50) {
  nodes {
    __typename
    ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id name dataType } } }
    ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id name dataType } } }
    ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id name dataType } } }
    ... on ProjectV2ItemFieldSingleSelectValue {
      name optionId
      field { ... on ProjectV2FieldCommon { id name dataType } }
    }
  }
}]]

local projects_query = [[query($owner: String!, $after: String) {
  %s(login: $owner) {
    projectsV2(first: 100, after: $after) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes { id number title items { totalCount } public closed url }
    }
  }
}]]

local detail_query = [[query($owner: String!, $number: Int!) {
  %s(login: $owner) {
    projectV2(number: $number) {
      id number title url public closed
      items { totalCount }
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField { options { id name color } }
        }
      }
      views(first: 10) { nodes { number name layout filter } }
    }
  }
}]]

local items_query = [[query($owner: String!, $number: Int!, $after: String, $filter: String) {
  %s(login: $owner) {
    projectV2(number: $number) {
      items(
        first: 100
        after: $after
        query: $filter
        orderBy: {field: POSITION, direction: ASC}
        archivedStates: [NOT_ARCHIVED]
      ) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          %s
        }
      }
    }
  }
}]]

local update_query = [[mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value}) {
    projectV2Item { id }
  }
}]]

local clear_query = [[mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
  clearProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId}) {
    projectV2Item { id }
  }
}]]

local add_item_query = [[mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
    item {
      %s
    }
  }
}]]

local add_draft_query = [[mutation($projectId: ID!, $title: String!, $body: String) {
  addProjectV2DraftIssue(input: {projectId: $projectId, title: $title, body: $body}) {
    projectItem {
      %s
    }
  }
}]]

local delete_query = [[mutation($projectId: ID!, $itemId: ID!) {
  deleteProjectV2Item(input: {projectId: $projectId, itemId: $itemId}) {
    deletedItemId
  }
}]]

local content_query = [[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { id }
      ... on PullRequest { id }
    }
  }
}]]

local body_query = [[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { body }
      ... on PullRequest { body }
    }
  }
}]]

local function missing(value)
  return value == nil or value == vim.NIL
end

local function failure(kind, reason)
  return { kind = kind, reason = reason }
end

local function invalid(reason)
  return failure("validation", reason)
end

local function invalid_response(what)
  return failure("unknown", "invalid " .. what .. " response")
end

local function classify(gh_failure)
  if type(gh_failure) ~= "table" then
    return failure("unknown", tostring(gh_failure))
  end
  local reason = gh_failure.reason or "GitHub request failed"
  local messages = type(gh_failure.errors) == "table" and gh_failure.errors or {}
  local detail = #messages > 0 and table.concat(messages, "; ") or reason
  local kind
  if gh_failure.status then
    kind = status_kinds[gh_failure.status] or "unknown"
  elseif reason:find("gh is not authenticated", 1, true) or reason:find("gh is not installed", 1, true) then
    kind = "auth"
  elseif reason:find("failed to start", 1, true) then
    kind = "network"
  elseif #messages > 0 then
    local text = table.concat(messages, "\n"):lower()
    if text:find("could not resolve", 1, true) then
      kind = "not_found"
    elseif text:find("temporary conflict", 1, true) then
      kind = "conflict"
    elseif text:find("rate limit", 1, true) then
      kind = "rate_limit"
    elseif text:find("scope", 1, true) or text:find("not authenticated", 1, true) then
      kind = "auth"
    elseif text:find("expected type", 1, true) or text:find("type mismatch", 1, true) then
      kind = "validation"
    else
      kind = "unknown"
    end
  else
    kind = "unknown"
  end
  return { kind = kind, reason = detail, errors = messages, status = gh_failure.status }
end

local function response_data(data)
  if type(data) == "table" and type(data.data) == "table" then
    return data.data
  end
  return nil
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value == math.floor(value) and value <= 9007199254740991
end

local function valid_login(owner)
  if type(owner) ~= "string" then
    return false
  end
  if #owner == 1 then
    return owner:match("^[%w]$") ~= nil
  end
  return owner:match("^[%w][%w%-]*[%w]$") ~= nil
end

local function valid_id(value)
  return type(value) == "string" and value ~= ""
end

local function valid_date(value)
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if year < 1 or year > 9999 or month < 1 or month > 12 or day < 1 then
    return false
  end
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
    days[2] = 29
  end
  return day <= days[month]
end

local function parse_reference(reference)
  if type(reference) ~= "string" then
    return nil, "invalid issue or pull request reference"
  end
  reference = reference:match("^%s*(.-)%s*$")
  local owner, repo, resource, number = reference:match("^https://github%.com/([%w%-]+)/([%w_.%-]+)/([%a]+)/(%d+)/?$")
  if owner and resource ~= "issues" and resource ~= "pull" then
    owner = nil
  end
  if not owner then
    owner, repo, number = reference:match("^([%w%-]+)/([%w_.%-]+)#(%d+)$")
  end
  if not owner or not valid_login(owner) then
    return nil, "invalid issue or pull request reference"
  end
  local value = tonumber(number)
  if not positive_integer(value) then
    return nil, "invalid issue or pull request number"
  end
  return { owner = owner, repo = repo, number = value }
end

local function parse_label(node)
  if type(node) ~= "table" or type(node.name) ~= "string" then
    return nil, "invalid label response"
  end
  return { name = node.name, color = type(node.color) == "string" and node.color or "" }
end

local function parse_assignee(node)
  if type(node) ~= "table" or type(node.login) ~= "string" then
    return nil, "invalid assignee response"
  end
  return { login = node.login }
end

local function parse_related_pull(node)
  if type(node) ~= "table" or type(node.number) ~= "number" or type(node.url) ~= "string" then
    return nil, "invalid related pull request response"
  end
  return { number = node.number, url = node.url }
end

local function parse_connection(connection, parse_node)
  if missing(connection) then
    return { total_count = 0, nodes = {} }
  end
  if type(connection) ~= "table" or type(connection.nodes) ~= "table" or not vim.islist(connection.nodes) then
    return nil, "invalid connection response"
  end
  local nodes = {}
  for _, node in ipairs(connection.nodes) do
    local parsed, err = parse_node(node)
    if not parsed then
      return nil, err
    end
    nodes[#nodes + 1] = parsed
  end
  local total = connection.totalCount
  if type(total) ~= "number" then
    total = 0
  end
  return { total_count = total, nodes = nodes }
end

local function parse_optional_connection(connection, parse_node)
  if missing(connection) then
    return nil
  end
  return parse_connection(connection, parse_node)
end

local function parse_sub_issues(summary)
  if missing(summary) then
    return nil
  end
  if type(summary) ~= "table" or type(summary.total) ~= "number" or type(summary.completed) ~= "number" then
    return nil, "invalid sub-issue summary response"
  end
  return { total = summary.total, completed = summary.completed }
end

local function repository_name(content)
  if type(content.repository) == "table" and type(content.repository.nameWithOwner) == "string" then
    return content.repository.nameWithOwner
  end
  return nil
end

local function parse_issue(content)
  if type(content.number) ~= "number" or type(content.title) ~= "string" then
    return nil, "invalid issue content response"
  end
  local labels, labels_err = parse_connection(content.labels, parse_label)
  if not labels then
    return nil, labels_err
  end
  local assignees, assignees_err = parse_connection(content.assignees, parse_assignee)
  if not assignees then
    return nil, assignees_err
  end
  local sub_issues, sub_issues_err = parse_sub_issues(content.subIssuesSummary)
  if sub_issues_err then
    return nil, sub_issues_err
  end
  local related_pulls, related_err =
    parse_optional_connection(content.closedByPullRequestsReferences, parse_related_pull)
  if related_err then
    return nil, related_err
  end
  return {
    number = content.number,
    title = content.title,
    state = type(content.state) == "string" and content.state or nil,
    url = type(content.url) == "string" and content.url or nil,
    repository = repository_name(content),
    labels = labels,
    assignees = assignees,
    sub_issues = sub_issues,
    related_pulls = related_pulls,
  }
end

local function parse_pull_request(content)
  if type(content.number) ~= "number" or type(content.title) ~= "string" then
    return nil, "invalid pull request content response"
  end
  local labels, labels_err = parse_connection(content.labels, parse_label)
  if not labels then
    return nil, labels_err
  end
  local assignees, assignees_err = parse_connection(content.assignees, parse_assignee)
  if not assignees then
    return nil, assignees_err
  end
  return {
    number = content.number,
    title = content.title,
    state = type(content.state) == "string" and content.state or nil,
    url = type(content.url) == "string" and content.url or nil,
    repository = repository_name(content),
    labels = labels,
    assignees = assignees,
  }
end

local function parse_draft_issue(content)
  if type(content.title) ~= "string" then
    return nil, "invalid draft issue content response"
  end
  local body = content.body
  if missing(body) then
    body = ""
  end
  if type(body) ~= "string" then
    return nil, "invalid draft issue body response"
  end
  return { title = content.title, body = body }
end

local function parse_content(content)
  if missing(content) then
    return nil
  end
  if type(content) ~= "table" then
    return nil, "invalid item content response"
  end
  if content.__typename == "Issue" then
    return parse_issue(content)
  elseif content.__typename == "PullRequest" then
    return parse_pull_request(content)
  elseif content.__typename == "DraftIssue" then
    return parse_draft_issue(content)
  end
  return nil
end

local function parse_values(connection)
  if missing(connection) then
    return {}
  end
  if type(connection) ~= "table" or type(connection.nodes) ~= "table" or not vim.islist(connection.nodes) then
    return nil, "invalid field values response"
  end
  local values = {}
  for _, node in ipairs(connection.nodes) do
    if type(node) == "table" and type(node.field) == "table" then
      local field = node.field
      if type(field.id) == "string" and type(field.dataType) == "string" and editable_types[field.dataType] then
        if node.__typename == "ProjectV2ItemFieldTextValue" and type(node.text) == "string" then
          values[field.id] = { kind = "text", value = node.text }
        elseif node.__typename == "ProjectV2ItemFieldNumberValue" and type(node.number) == "number" then
          values[field.id] = { kind = "number", value = node.number }
        elseif node.__typename == "ProjectV2ItemFieldDateValue" and type(node.date) == "string" then
          values[field.id] = { kind = "date", value = node.date }
        elseif node.__typename == "ProjectV2ItemFieldSingleSelectValue" and type(node.optionId) == "string" then
          values[field.id] = {
            kind = "single_select",
            value = node.optionId,
            option_id = node.optionId,
            name = type(node.name) == "string" and node.name or "",
          }
        end
      end
    end
  end
  return values
end

local function parse_item(node)
  if type(node) ~= "table" or not valid_id(node.id) or type(node.type) ~= "string" then
    return nil, "invalid project item response"
  end
  local content, content_err = parse_content(node.content)
  if content_err then
    return nil, content_err
  end
  local values, values_err = parse_values(node.fieldValues)
  if not values then
    return nil, values_err
  end
  return {
    id = node.id,
    type = node.type,
    content = content,
    values = values,
    archived = node.isArchived == true,
  }
end

local function parse_field(node)
  if
    type(node) ~= "table"
    or not valid_id(node.id)
    or type(node.name) ~= "string"
    or type(node.dataType) ~= "string"
  then
    return nil, "invalid field response"
  end
  local options = {}
  if node.dataType == "SINGLE_SELECT" then
    if not missing(node.options) then
      if type(node.options) ~= "table" or not vim.islist(node.options) then
        return nil, "invalid field options response"
      end
      for _, option in ipairs(node.options) do
        if
          type(option) ~= "table"
          or not valid_id(option.id)
          or type(option.name) ~= "string"
          or type(option.color) ~= "string"
        then
          return nil, "invalid field option response"
        end
        options[#options + 1] = { id = option.id, name = option.name, color = option.color }
      end
    end
  end
  return { id = node.id, name = node.name, dataType = node.dataType, options = options }
end

local function parse_view(node)
  if type(node) ~= "table" or type(node.number) ~= "number" or type(node.name) ~= "string" then
    return nil, "invalid view response"
  end
  local layout = node.layout
  if type(layout) ~= "string" then
    return nil, "invalid view layout response"
  end
  local filter = node.filter
  if missing(filter) then
    filter = ""
  end
  if type(filter) ~= "string" then
    return nil, "invalid view filter response"
  end
  return { number = node.number, name = node.name, layout = layout, filter = filter }
end

local function resolve_group_field(fields, group_by)
  local first_single
  for _, field in ipairs(fields) do
    if field.dataType == "SINGLE_SELECT" then
      if field.name == group_by then
        return field
      end
      first_single = first_single or field
    end
  end
  return first_single
end

function M.new(opts)
  opts = opts or {}
  local client = opts.client or require("github.core.gh").new(opts.run)
  local host = opts.host or "github.com"
  local function settings()
    if opts.projects then
      return opts.projects
    end
    return require("github.core.config").projects()
  end

  local function resolve_owner(target, callback)
    local target_host = target and target.host
    if type(target_host) ~= "string" or target_host == "" then
      return callback(nil, invalid("invalid host"))
    end
    local owner = target.owner
    local endpoint
    if missing(owner) or owner == "@me" then
      endpoint = "user"
    elseif not valid_login(owner) then
      return callback(nil, invalid("invalid owner: " .. tostring(owner)))
    else
      endpoint = "users/" .. owner
    end
    client.rest({ host = target_host }, "GET", endpoint, nil, function(data, gh_failure)
      if not data then
        return callback(nil, classify(gh_failure))
      end
      if type(data) ~= "table" or not valid_id(data.login) or (data.type ~= "User" and data.type ~= "Organization") then
        return callback(nil, invalid_response("owner"))
      end
      callback({ host = target_host, owner = data.login, type = data.type })
    end)
  end

  local function project_root(resolved)
    if
      type(resolved) ~= "table"
      or type(resolved.host) ~= "string"
      or not valid_id(resolved.owner)
      or (resolved.type ~= "User" and resolved.type ~= "Organization")
    then
      return nil
    end
    return resolved.type == "User" and "user" or "organization"
  end

  local function list_projects(resolved, callback)
    local root = project_root(resolved)
    if not root then
      return callback(nil, invalid("invalid project target"))
    end
    local query = projects_query:format(root)
    local target = { host = resolved.host, owner = resolved.owner }
    local collected, total_count, pages, seen = {}, nil, 0, {}
    local function finish(truncated)
      callback({ projects = collected, total_count = total_count or 0, truncated = truncated })
    end
    local function next_page(cursor)
      pages = pages + 1
      client.graphql(target, query, { owner = resolved.owner, after = cursor }, function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local connection = body and body[root] and body[root].projectsV2
        if
          type(connection) ~= "table"
          or type(connection.nodes) ~= "table"
          or not vim.islist(connection.nodes)
          or type(connection.pageInfo) ~= "table"
          or type(connection.pageInfo.hasNextPage) ~= "boolean"
          or type(connection.totalCount) ~= "number"
        then
          return callback(nil, invalid_response("projects"))
        end
        if total_count == nil then
          total_count = connection.totalCount
        end
        for _, node in ipairs(connection.nodes) do
          if
            type(node) ~= "table"
            or not valid_id(node.id)
            or type(node.number) ~= "number"
            or type(node.title) ~= "string"
            or type(node.items) ~= "table"
            or type(node.items.totalCount) ~= "number"
            or type(node.public) ~= "boolean"
            or type(node.closed) ~= "boolean"
            or type(node.url) ~= "string"
          then
            return callback(nil, invalid_response("project"))
          end
          if not node.closed then
            collected[#collected + 1] = {
              id = node.id,
              number = node.number,
              title = node.title,
              item_count = node.items.totalCount,
              public = node.public,
              closed = node.closed,
              url = node.url,
            }
          end
        end
        local more = connection.pageInfo.hasNextPage
        local over = #collected > 100
        if over then
          for index = #collected, 101, -1 do
            table.remove(collected, index)
          end
        end
        if #collected >= 100 or pages >= 10 or not more then
          return finish((more and (#collected >= 100 or pages >= 10)) or over)
        end
        local next_cursor = connection.pageInfo.endCursor
        if type(next_cursor) ~= "string" or next_cursor == "" or seen[next_cursor] then
          return callback(nil, invalid_response("project pagination"))
        end
        seen[next_cursor] = true
        next_page(next_cursor)
      end)
    end
    next_page(nil)
  end

  local function detail(resolved, number, callback)
    local root = project_root(resolved)
    if not root then
      return callback(nil, invalid("invalid project target"))
    end
    if not positive_integer(number) then
      return callback(nil, invalid("invalid project number"))
    end
    local query = detail_query:format(root)
    client.graphql(
      { host = resolved.host, owner = resolved.owner },
      query,
      { owner = resolved.owner, number = number },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local project = body and body[root] and body[root].projectV2
        if missing(project) then
          return callback(nil, failure("not_found", "project not found"))
        end
        if
          type(project) ~= "table"
          or not valid_id(project.id)
          or type(project.number) ~= "number"
          or type(project.title) ~= "string"
          or type(project.url) ~= "string"
          or type(project.public) ~= "boolean"
          or type(project.closed) ~= "boolean"
          or type(project.items) ~= "table"
          or type(project.items.totalCount) ~= "number"
        then
          return callback(nil, invalid_response("project"))
        end
        if
          type(project.fields) ~= "table"
          or type(project.fields.nodes) ~= "table"
          or not vim.islist(project.fields.nodes)
          or type(project.views) ~= "table"
          or type(project.views.nodes) ~= "table"
          or not vim.islist(project.views.nodes)
        then
          return callback(nil, invalid_response("project detail"))
        end
        local fields = {}
        for _, node in ipairs(project.fields.nodes) do
          local field, field_err = parse_field(node)
          if not field then
            return callback(nil, failure("unknown", field_err))
          end
          if editable_types[field.dataType] then
            fields[#fields + 1] = field
          end
        end
        local views = {}
        for _, node in ipairs(project.views.nodes) do
          local view, view_err = parse_view(node)
          if not view then
            return callback(nil, failure("unknown", view_err))
          end
          views[#views + 1] = view
        end
        table.sort(views, function(a, b)
          return a.number < b.number
        end)
        local first_view = views[1]
        callback({
          project = {
            id = project.id,
            number = project.number,
            title = project.title,
            item_count = project.items.totalCount,
            public = project.public,
            closed = project.closed,
            url = project.url,
          },
          fields = fields,
          group_field = resolve_group_field(fields, settings().group_by),
          views = views,
          view = first_view,
          filter = first_view and first_view.filter or "",
        })
      end
    )
  end

  local function items(resolved, number, filter, callback)
    local root = project_root(resolved)
    if not root then
      return callback(nil, invalid("invalid project target"))
    end
    if not positive_integer(number) then
      return callback(nil, invalid("invalid project number"))
    end
    if filter ~= nil and type(filter) ~= "string" then
      return callback(nil, invalid("invalid project filter"))
    end
    filter = filter or ""
    local max_items = settings().max_items
    if type(max_items) ~= "number" or max_items < 1 or max_items ~= math.floor(max_items) then
      max_items = 1000
    end
    local query = items_query:format(root, item_fields)
    local target = { host = resolved.host, owner = resolved.owner }
    local collected, total_count, seen = {}, nil, {}
    local function finish(truncated)
      if #collected > max_items then
        for index = #collected, max_items + 1, -1 do
          table.remove(collected, index)
        end
      end
      callback({ items = collected, total_count = total_count or 0, truncated = truncated })
    end
    local function next_page(cursor)
      client.graphql(
        target,
        query,
        { owner = resolved.owner, number = number, after = cursor, filter = filter },
        function(data, gh_failure)
          if not data then
            return callback(nil, classify(gh_failure))
          end
          local body = response_data(data)
          local project = body and body[root] and body[root].projectV2
          if missing(project) then
            return callback(nil, failure("not_found", "project not found"))
          end
          if type(project) ~= "table" then
            return callback(nil, invalid_response("project"))
          end
          local connection = project.items
          if
            type(connection) ~= "table"
            or type(connection.nodes) ~= "table"
            or not vim.islist(connection.nodes)
            or type(connection.pageInfo) ~= "table"
            or type(connection.pageInfo.hasNextPage) ~= "boolean"
          then
            return callback(nil, invalid_response("items"))
          end
          if total_count == nil then
            if type(connection.totalCount) ~= "number" then
              return callback(nil, invalid_response("items"))
            end
            total_count = connection.totalCount
          end
          for _, node in ipairs(connection.nodes) do
            local item, item_err = parse_item(node)
            if not item then
              return callback(nil, failure("unknown", item_err))
            end
            collected[#collected + 1] = item
          end
          local more = connection.pageInfo.hasNextPage
          local over = #collected > max_items
          if #collected >= max_items or not more then
            return finish(more or over)
          end
          local next_cursor = connection.pageInfo.endCursor
          if type(next_cursor) ~= "string" or next_cursor == "" or seen[next_cursor] then
            return callback(nil, invalid_response("item pagination"))
          end
          seen[next_cursor] = true
          next_page(next_cursor)
        end
      )
    end
    next_page(nil)
  end

  local function mutation_item_id(body, mutation_key)
    local mutation = body and body[mutation_key]
    local item = type(mutation) == "table" and mutation.projectV2Item
    if type(item) ~= "table" or not valid_id(item.id) then
      return nil
    end
    return item.id
  end

  local function clear_field(project_id, item_id, field_id, callback)
    if not valid_id(project_id) then
      return callback(nil, invalid("invalid project ID"))
    end
    if not valid_id(item_id) then
      return callback(nil, invalid("invalid item ID"))
    end
    if not valid_id(field_id) then
      return callback(nil, invalid("invalid field ID"))
    end
    client.graphql(
      { host = host },
      clear_query,
      { projectId = project_id, itemId = item_id, fieldId = field_id },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        if mutation_item_id(response_data(data), "clearProjectV2ItemFieldValue") ~= item_id then
          return callback(nil, invalid_response("field clear"))
        end
        callback({ item_id = item_id, field_id = field_id })
      end
    )
  end

  local function update_field(project_id, item_id, field, value, callback)
    if not valid_id(project_id) then
      return callback(nil, invalid("invalid project ID"))
    end
    if not valid_id(item_id) then
      return callback(nil, invalid("invalid item ID"))
    end
    if type(field) ~= "table" or not valid_id(field.id) or type(field.dataType) ~= "string" then
      return callback(nil, invalid("invalid field"))
    end
    local field_value, result_value
    if field.dataType == "TEXT" then
      if value == "" then
        return clear_field(project_id, item_id, field.id, callback)
      end
      if type(value) ~= "string" then
        return callback(nil, invalid("text value must be a string"))
      end
      field_value = { text = value }
      result_value = { kind = "text", value = value }
    elseif field.dataType == "NUMBER" then
      local number = tonumber(value)
      if not number or number ~= number or number == math.huge or number == -math.huge then
        return callback(nil, invalid("number value must be finite"))
      end
      field_value = { number = number }
      result_value = { kind = "number", value = number }
    elseif field.dataType == "DATE" then
      if type(value) ~= "string" or not valid_date(value) then
        return callback(nil, invalid("date value must be YYYY-MM-DD and exist"))
      end
      field_value = { date = value }
      result_value = { kind = "date", value = value }
    elseif field.dataType == "SINGLE_SELECT" then
      if type(value) ~= "string" then
        return callback(nil, invalid("single-select option is required"))
      end
      local option
      for _, candidate in ipairs(field.options or {}) do
        if candidate.id == value then
          option = candidate
          break
        end
      end
      if not option then
        return callback(nil, invalid("unknown option id: " .. value))
      end
      field_value = { singleSelectOptionId = value }
      result_value = { kind = "single_select", value = value, option_id = value, name = option.name }
    else
      return callback(nil, invalid("unsupported field type: " .. tostring(field.dataType)))
    end
    client.graphql(
      { host = host },
      update_query,
      { projectId = project_id, itemId = item_id, fieldId = field.id, value = field_value },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        if mutation_item_id(response_data(data), "updateProjectV2ItemFieldValue") ~= item_id then
          return callback(nil, invalid_response("field update"))
        end
        callback({ item_id = item_id, field_id = field.id, value = result_value })
      end
    )
  end

  local function resolve_content(target, reference, callback)
    local target_host = target and target.host
    if type(target_host) ~= "string" or target_host == "" then
      return callback(nil, invalid("invalid host"))
    end
    local parsed, reference_err = parse_reference(reference)
    if not parsed then
      return callback(nil, invalid(reference_err))
    end
    client.graphql(
      { host = target_host },
      content_query,
      { owner = parsed.owner, repo = parsed.repo, number = parsed.number },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local repository = body and body.repository
        if missing(repository) then
          return callback(nil, failure("not_found", "issue or pull request not found"))
        end
        if type(repository) ~= "table" then
          return callback(nil, invalid_response("repository"))
        end
        local node = repository.issueOrPullRequest
        if missing(node) then
          return callback(nil, failure("not_found", "issue or pull request not found"))
        end
        if
          type(node) ~= "table"
          or not valid_id(node.id)
          or (node.__typename ~= "Issue" and node.__typename ~= "PullRequest")
        then
          return callback(nil, invalid_response("issue or pull request"))
        end
        callback({
          id = node.id,
          type = node.__typename,
          owner = parsed.owner,
          repo = parsed.repo,
          number = parsed.number,
        })
      end
    )
  end

  local function add_item(project_id, content_id, existing_ids, callback)
    if not valid_id(project_id) then
      return callback(nil, invalid("invalid project ID"))
    end
    if not valid_id(content_id) then
      return callback(nil, invalid("invalid content ID"))
    end
    client.graphql(
      { host = host },
      add_item_query:format(item_fields),
      { projectId = project_id, contentId = content_id },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local mutation = body and body.addProjectV2ItemById
        local node = type(mutation) == "table" and mutation.item
        if type(node) ~= "table" then
          return callback(nil, invalid_response("item addition"))
        end
        local item, item_err = parse_item(node)
        if not item then
          return callback(nil, failure("unknown", item_err))
        end
        local duplicate = false
        if type(existing_ids) == "table" then
          if existing_ids[item.id] then
            duplicate = true
          else
            for _, value in pairs(existing_ids) do
              if value == item.id or (type(value) == "table" and value.id == item.id) then
                duplicate = true
                break
              end
            end
          end
        end
        callback({ item = item, duplicate = duplicate })
      end
    )
  end

  local function add_draft(project_id, title, body, callback)
    if not valid_id(project_id) then
      return callback(nil, invalid("invalid project ID"))
    end
    if type(title) ~= "string" then
      return callback(nil, invalid("draft title must be a string"))
    end
    title = title:match("^%s*(.-)%s*$")
    if #title == 0 then
      return callback(nil, invalid("draft title must not be empty"))
    end
    if missing(body) then
      body = ""
    end
    if type(body) ~= "string" then
      return callback(nil, invalid("draft body must be a string"))
    end
    client.graphql(
      { host = host },
      add_draft_query:format(item_fields),
      { projectId = project_id, title = title, body = body },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body_data = response_data(data)
        local mutation = body_data and body_data.addProjectV2DraftIssue
        local node = type(mutation) == "table" and mutation.projectItem
        if type(node) ~= "table" then
          return callback(nil, invalid_response("draft issue addition"))
        end
        local item, item_err = parse_item(node)
        if not item then
          return callback(nil, failure("unknown", item_err))
        end
        callback({ item = item })
      end
    )
  end

  local function delete_item(project_id, item_id, callback)
    if not valid_id(project_id) then
      return callback(nil, invalid("invalid project ID"))
    end
    if not valid_id(item_id) then
      return callback(nil, invalid("invalid item ID"))
    end
    client.graphql(
      { host = host },
      delete_query,
      { projectId = project_id, itemId = item_id },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local mutation = body and body.deleteProjectV2Item
        if type(mutation) ~= "table" then
          return callback(nil, invalid_response("item deletion"))
        end
        local deleted = mutation.deletedItemId
        if missing(deleted) then
          return callback(nil, failure("not_found", "project item not found"))
        end
        if type(deleted) ~= "string" or deleted ~= item_id then
          return callback(nil, invalid_response("item deletion"))
        end
        callback({ item_id = deleted })
      end
    )
  end

  local function fetch_body(target, repository, number, callback)
    local target_host = target and target.host
    if type(target_host) ~= "string" or target_host == "" then
      return callback(nil, invalid("invalid host"))
    end
    local owner, repo
    if type(repository) == "string" then
      owner, repo = repository:match("^([%w%-]+)/([%w_.%-]+)$")
    end
    if not owner or not valid_login(owner) then
      return callback(nil, invalid("invalid repository"))
    end
    if not positive_integer(number) then
      return callback(nil, invalid("invalid issue number"))
    end
    client.graphql(
      { host = target_host },
      body_query,
      { owner = owner, repo = repo, number = number },
      function(data, gh_failure)
        if not data then
          return callback(nil, classify(gh_failure))
        end
        local body = response_data(data)
        local repository_data = body and body.repository
        if missing(repository_data) then
          return callback(nil, failure("not_found", "issue or pull request not found"))
        end
        if type(repository_data) ~= "table" then
          return callback(nil, invalid_response("repository"))
        end
        local node = repository_data.issueOrPullRequest
        if missing(node) then
          return callback(nil, failure("not_found", "issue or pull request not found"))
        end
        if type(node) ~= "table" or (node.__typename ~= "Issue" and node.__typename ~= "PullRequest") then
          return callback(nil, invalid_response("issue or pull request"))
        end
        local text = node.body
        if missing(text) then
          text = ""
        end
        if type(text) ~= "string" then
          return callback(nil, invalid_response("issue or pull request body"))
        end
        callback({ type = node.__typename, body = text })
      end
    )
  end

  return {
    resolve_owner = resolve_owner,
    list_projects = list_projects,
    detail = detail,
    items = items,
    fetch_body = fetch_body,
    update_field = update_field,
    clear_field = clear_field,
    resolve_content = resolve_content,
    add_item = add_item,
    add_draft = add_draft,
    delete_item = delete_item,
  }
end

return M
