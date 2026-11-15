local M = {}

local cache = require("github.core.cache")
local gh = require("github.core.gh")

local TTL = 300000

local queries = {
  assignable_users = [[query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    assignableUsers(first: 100, after: $cursor) {
      nodes { id login }
      pageInfo { hasNextPage endCursor }
    }
  }
}]],
  labels = [[query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    labels(first: 100, after: $cursor) {
      nodes { id name color }
      pageInfo { hasNextPage endCursor }
    }
  }
}]],
  projects = [[query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    projectsV2(first: 100, after: $cursor) {
      nodes { id title }
      pageInfo { hasNextPage endCursor }
    }
  }
}]],
  fields = [[query($project: ID!, $cursor: String) {
  node(id: $project) {
    ... on ProjectV2 {
      fields(first: 50, after: $cursor) {
        nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]],
  update_issue = [[mutation($input: UpdateIssueInput!) {
  updateIssue(input: $input) { issue { id } }
}]],
  add_item = [[mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) { item { id } }
}]],
  delete_item = [[mutation($projectId: ID!, $itemId: ID!) {
  deleteProjectV2Item(input: {projectId: $projectId, itemId: $itemId}) { deletedItemId }
}]],
  update_field = [[mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value}) {
    projectV2Item { id }
  }
}]],
  clear_field = [[mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
  clearProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId}) {
    projectV2Item { id }
  }
}]],
}

local function key(target, kind)
  return kind .. ":" .. tostring(target.host) .. "/" .. tostring(target.owner) .. "/" .. tostring(target.repo)
end

local function fetch_connection(target, query, variables, extract, callback)
  local items = {}
  gh.paginate(function(cursor, next_page)
    local vars = vim.deepcopy(variables)
    vars.cursor = cursor
    gh.new().graphql(target, query, vars, function(data, err)
      if not data then
        return next_page(nil, err)
      end
      local payload = type(data.data) == "table" and data.data
      local connection = payload and extract(payload)
      if type(connection) ~= "table" or type(connection.nodes) ~= "table" then
        return next_page(nil, "invalid response")
      end
      next_page({ items = connection.nodes, pageInfo = connection.pageInfo })
    end)
  end, function(nodes, err)
    if not nodes then
      return callback(nil, err)
    end
    for _, node in ipairs(nodes) do
      items[#items + 1] = node
    end
    callback(items)
  end)
end

function M.assignable_users(target, callback)
  cache.fetch(key(target, "users"), TTL, function(done)
    fetch_connection(target, queries.assignable_users, { owner = target.owner, repo = target.repo }, function(payload)
      return payload.repository and payload.repository.assignableUsers
    end, function(nodes, err)
      if not nodes then
        return done(nil, err)
      end
      local items = {}
      for _, node in ipairs(nodes) do
        if type(node) == "table" and type(node.id) == "string" and type(node.login) == "string" then
          items[#items + 1] = { id = node.id, login = node.login }
        end
      end
      done(items)
    end)
  end, callback)
end

function M.labels(target, callback)
  cache.fetch(key(target, "labels"), TTL, function(done)
    fetch_connection(target, queries.labels, { owner = target.owner, repo = target.repo }, function(payload)
      return payload.repository and payload.repository.labels
    end, function(nodes, err)
      if not nodes then
        return done(nil, err)
      end
      local items = {}
      for _, node in ipairs(nodes) do
        if type(node) == "table" and type(node.id) == "string" and type(node.name) == "string" then
          items[#items + 1] = {
            id = node.id,
            name = node.name,
            color = type(node.color) == "string" and node.color or "",
          }
        end
      end
      done(items)
    end)
  end, callback)
end

function M.projects(target, callback)
  cache.fetch(key(target, "projects"), TTL, function(done)
    fetch_connection(target, queries.projects, { owner = target.owner, repo = target.repo }, function(payload)
      return payload.repository and payload.repository.projectsV2
    end, function(nodes, err)
      if not nodes then
        return done(nil, err)
      end
      local items = {}
      for _, node in ipairs(nodes) do
        if type(node) == "table" and type(node.id) == "string" and type(node.title) == "string" then
          items[#items + 1] = { id = node.id, title = node.title }
        end
      end
      done(items)
    end)
  end, callback)
end

function M.project_fields(target, project_id, callback)
  cache.fetch("fields:" .. project_id, TTL, function(done)
    fetch_connection(target, queries.fields, { project = project_id }, function(payload)
      local node = payload.node
      return node and node.fields
    end, function(nodes, err)
      if not nodes then
        return done(nil, err)
      end
      local fields = {}
      for _, node in ipairs(nodes) do
        if type(node) == "table" and type(node.id) == "string" and type(node.name) == "string" then
          local options = {}
          for _, option in ipairs(type(node.options) == "table" and node.options or {}) do
            if type(option) == "table" and type(option.id) == "string" and type(option.name) == "string" then
              options[#options + 1] = { id = option.id, name = option.name }
            end
          end
          fields[#fields + 1] = { id = node.id, name = node.name, options = options }
        end
      end
      done(fields)
    end)
  end, callback)
end

function M.resolve_assignees(target, logins, callback)
  M.assignable_users(target, function(items, err)
    if not items then
      return callback(nil, err)
    end
    local by_login = {}
    for _, item in ipairs(items) do
      by_login[item.login:lower()] = item
    end
    local ids, seen, resolved = {}, {}, {}
    for _, login in ipairs(logins) do
      local lookup = login:lower()
      local item = by_login[lookup]
      if not item then
        return callback(nil, "Invalid or unavailable assignee: " .. login)
      end
      if not seen[lookup] then
        seen[lookup] = true
        ids[#ids + 1] = item.id
        resolved[#resolved + 1] = item
      end
    end
    callback({ ids = ids, items = resolved })
  end)
end

function M.resolve_labels(target, names, callback)
  M.labels(target, function(items, err)
    if not items then
      return callback(nil, err)
    end
    local by_name = {}
    for _, item in ipairs(items) do
      by_name[item.name] = item
    end
    local ids, seen, resolved = {}, {}, {}
    for _, name in ipairs(names) do
      local item = by_name[name]
      if not item then
        return callback(nil, "Invalid or unavailable label: " .. name)
      end
      if not seen[name] then
        seen[name] = true
        ids[#ids + 1] = item.id
        resolved[#resolved + 1] = item
      end
    end
    callback({ ids = ids, items = resolved })
  end)
end

function M.resolve_projects(target, titles, callback)
  M.projects(target, function(items, err)
    if not items then
      return callback(nil, err)
    end
    local by_title = {}
    for _, item in ipairs(items) do
      by_title[item.title] = item
    end
    local ids, resolved = {}, {}
    for _, title in ipairs(titles) do
      local item = by_title[title]
      if not item then
        return callback(nil, "Invalid or unavailable project: " .. title)
      end
      ids[#ids + 1] = item.id
      resolved[#resolved + 1] = item
    end
    callback({ ids = ids, items = resolved })
  end)
end

function M.resolve_field(target, project_id, field_name, callback)
  M.project_fields(target, project_id, function(fields, err)
    if not fields then
      return callback(nil, err)
    end
    for _, field in ipairs(fields) do
      if field.name:lower() == field_name:lower() then
        return callback(field)
      end
    end
    callback(nil, "Project field not found: " .. field_name)
  end)
end

function M.resolve_status(target, project_id, field_name, value, callback)
  M.resolve_field(target, project_id, field_name, function(field, err)
    if not field then
      return callback(nil, err)
    end
    for _, option in ipairs(field.options) do
      if option.name == value then
        return callback({ field = field, option = option })
      end
    end
    callback(nil, "Invalid " .. field_name .. " value: " .. value)
  end)
end

function M.update_issue(target, input, callback)
  gh.new().graphql(target, queries.update_issue, { input = input }, function(data, failure)
    local update = type(data) == "table" and type(data.data) == "table" and data.data.updateIssue
    local issue = type(update) == "table" and update.issue
    if type(issue) ~= "table" or issue.id ~= input.id then
      return callback(nil, failure and failure.reason or "invalid update response")
    end
    callback(true)
  end)
end

function M.add_project_item(target, project_id, content_id, callback)
  gh.new().graphql(target, queries.add_item, { projectId = project_id, contentId = content_id }, function(data, failure)
    local result = type(data) == "table" and type(data.data) == "table" and data.data.addProjectV2ItemById
    local item = type(result) == "table" and result.item
    if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
      return callback(nil, failure and failure.reason or "invalid add response")
    end
    callback(item.id)
  end)
end

function M.delete_project_item(target, project_id, item_id, callback)
  gh.new().graphql(target, queries.delete_item, { projectId = project_id, itemId = item_id }, function(data, failure)
    local result = type(data) == "table" and type(data.data) == "table" and data.data.deleteProjectV2Item
    if type(result) ~= "table" or result.deletedItemId ~= item_id then
      return callback(nil, failure and failure.reason or "invalid delete response")
    end
    callback(true)
  end)
end

function M.update_project_field(target, project_id, item_id, field_id, option_id, callback)
  gh.new().graphql(target, queries.update_field, {
    projectId = project_id,
    itemId = item_id,
    fieldId = field_id,
    value = { singleSelectOptionId = option_id },
  }, function(data, failure)
    local result = type(data) == "table" and type(data.data) == "table" and data.data.updateProjectV2ItemFieldValue
    local item = type(result) == "table" and result.projectV2Item
    if type(item) ~= "table" or item.id ~= item_id then
      return callback(nil, failure and failure.reason or "invalid field update response")
    end
    callback(true)
  end)
end

function M.clear_project_field(target, project_id, item_id, field_id, callback)
  gh.new().graphql(
    target,
    queries.clear_field,
    { projectId = project_id, itemId = item_id, fieldId = field_id },
    function(data, failure)
      local result = type(data) == "table" and type(data.data) == "table" and data.data.clearProjectV2ItemFieldValue
      local item = type(result) == "table" and result.projectV2Item
      if type(item) ~= "table" or item.id ~= item_id then
        return callback(nil, failure and failure.reason or "invalid field clear response")
      end
      callback(true)
    end
  )
end

return M
