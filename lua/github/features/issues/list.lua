local M = {}
local states = {}
local request = require("github.core.request")
local gh = require("github.core.gh")
local query = [[query($query: String!) {
  search(first: 30, type: ISSUE, query: $query) {
    nodes { ... on %s { __typename id number title state body url
      repository { name owner { login } }
      comments { totalCount }
      assignees(first: 100) { nodes { login } pageInfo { hasNextPage endCursor } }
      labels(first: 100) { nodes { name } pageInfo { hasNextPage endCursor } }
    } }
  }
}]]
local page_query = [[query($id: ID!, $cursor: String!, $assignees: Boolean!) {
  node(id: $id) { ... on %s {
    assignees(first: 100, after: $cursor) @include(if: $assignees) {
      nodes { login } pageInfo { hasNextPage endCursor }
    }
    labels(first: 100, after: $cursor) @skip(if: $assignees) { nodes { name } pageInfo { hasNextPage endCursor } }
  } }
}]]
local function notify_error(state, err)
  local reason = type(err) == "table" and err.reason or tostring(err)
  vim.notify("GitHub " .. state.target.owner .. "/" .. state.target.repo .. ": " .. reason, vim.log.levels.ERROR)
end
local function render(buf, state)
  local lines, spans =
    require("github.core.rows").issues(state.items, state.selected, state.pull and "pull requests" or nil)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  require("github.core.highlight").set(buf, spans)
end
local function complete_connections(client, state, nodes, done)
  local i, kinds = 1, { "assignees", "labels" }
  local function next_issue()
    if i > #nodes then
      return done(nodes)
    end
    local item = nodes[i]
    local k = 1
    local function next_kind()
      if k > #kinds then
        i = i + 1
        return next_issue()
      end
      local name = kinds[k]
      local connection = item[name]
      if
        type(connection) ~= "table"
        or type(connection.nodes) ~= "table"
        or type(connection.pageInfo) ~= "table"
        or type(connection.pageInfo.hasNextPage) ~= "boolean"
      then
        return done(nil, "invalid " .. name .. " connection")
      end
      if not connection.pageInfo.hasNextPage then
        k = k + 1
        return next_kind()
      end
      if type(item.id) ~= "string" or item.id == "" then
        return done(nil, "missing issue ID for pagination")
      end
      local cursor = connection.pageInfo.endCursor
      local seen = {}
      local function next_page()
        if type(cursor) ~= "string" or cursor == "" or seen[cursor] then
          return done(nil, "invalid pagination cursor")
        end
        seen[cursor] = true
        client.graphql(
          state.target,
          page_query:format(state.node_type),
          { id = item.id, cursor = cursor, assignees = name == "assignees" },
          function(data, err)
            local result = data and data.data and data.data.node and data.data.node[name]
            if not result then
              return done(nil, err or "invalid pagination response")
            end
            if
              type(result.nodes) ~= "table"
              or type(result.pageInfo) ~= "table"
              or type(result.pageInfo.hasNextPage) ~= "boolean"
            then
              return done(nil, "invalid pagination response")
            end
            vim.list_extend(connection.nodes, result.nodes)
            if result.pageInfo.hasNextPage then
              cursor = result.pageInfo.endCursor
              return next_page()
            end
            k = k + 1
            next_kind()
          end
        )
      end
      next_page()
    end
    next_kind()
  end
  next_issue()
end
function M.search(buf, condition)
  local state = states[buf]
  if not state then
    return
  end
  state.revision = (state.revision or 0) + 1
  state.selected = {}
  if state.success then
    render(buf, state)
  end
  local token = request.begin(buf)
  local client = gh.new()
  client.graphql(state.target, query:format(state.node_type), {
    query = "repo:"
      .. state.target.owner
      .. "/"
      .. state.target.repo
      .. (state.pull and " type:pr " or " type:issue ")
      .. condition,
  }, function(data, err)
    request.apply(token, function()
      local function fail(reason)
        request.finish(token)
        notify_error(state, reason)
        if not state.success then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            { state.pull and "Pull request search failed" or "Issue search failed" }
          )
          vim.bo[buf].modifiable = false
        end
      end
      local nodes = data and data.data and data.data.search and data.data.search.nodes
      if type(nodes) ~= "table" then
        return fail(err or "invalid search response")
      end
      for _, item in ipairs(nodes) do
        if state.pull and item.__typename ~= "PullRequest" then
          return fail("search returned a non-pull-request result")
        end
        local repo = item.repository
        if
          not repo
          or not repo.owner
          or type(repo.owner.login) ~= "string"
          or type(repo.name) ~= "string"
          or repo.owner.login:lower() ~= state.target.owner:lower()
          or repo.name:lower() ~= state.target.repo:lower()
        then
          return fail("search returned an issue from another repository")
        end
      end
      complete_connections(client, state, nodes, function(items, failure)
        request.apply(token, function()
          if not items then
            return fail(failure)
          end
          state.items, state.condition, state.success = items, condition, true
          render(buf, state)
        end)
      end)
    end, true)
  end)
end
local function toggle(buf, delta)
  local state = states[buf]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if not state.items[row] then
    return
  end
  state.selected[row] = not state.selected[row] or nil
  render(buf, state)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(#state.items, row + delta)), 0 })
end
local function preview(buf)
  local state = states[buf]
  local item = state.items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  require("github.core.view").preview(item.body or "")
end
function M.read(buf, target)
  local state = states[buf]
  if not state then
    state = {
      target = target,
      items = {},
      selected = {},
      condition = "state:open",
      pull = target.kind == "pull_list",
      node_type = target.kind == "pull_list" and "PullRequest" or "Issue",
    }
    states[buf] = state
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
    if not state.pull then
      require("github.features.issues.state").attach(buf)
    end
    require("github.core.navigation").configure(buf, state.pull and "gh-pulls" or "gh-issues")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    if not state.pull then
      require("github.core.navigation").map(buf, "ghn", "gh:issue:new", function()
        require("github.features.issues.create").open_from_list(buf)
      end)
    end
    local prefix = state.pull and "gh:pull:" or "gh:issue:"
    require("github.core.navigation").map(buf, "ghs", prefix .. "search", function()
      require("github.core.view").search(buf, state.condition, function(value)
        if value ~= nil then
          M.search(buf, value)
        end
      end, function()
        return state.condition
      end)
    end)
    if not state.pull then
      local function edit(field)
        local item = state.items[vim.api.nvim_win_get_cursor(0)[1]]
        if not item then
          return
        end
        if field == "body" and next(state.selected) then
          vim.notify(
            "GitHub " .. target.owner .. "/" .. target.repo .. ": clear the selection before editing the body",
            vim.log.levels.WARN
          )
          return
        end
        local destination = {
          kind = "issue_edit",
          host = target.host,
          owner = target.owner,
          repo = target.repo,
          issue_number = item.number,
        }
        local editor = require("github.features.issues.edit")
        if field == "title" then
          editor.open_title(destination)
        else
          editor.open_body(destination)
        end
      end
      require("github.core.navigation").map(buf, "ght", "gh:issue:edit:title", function()
        edit("title")
      end)
      require("github.core.navigation").map(buf, "ghe", "gh:issue:edit", function()
        edit("body")
      end)
      require("github.core.navigation").map(buf, "gha", "gh:issue:assignees", function()
        require("github.features.issues.attributes").open_from_list(buf, "assignees")
      end)
      require("github.core.navigation").map(buf, "ghl", "gh:issue:labels", function()
        require("github.features.issues.attributes").open_from_list(buf, "labels")
      end)
      require("github.core.navigation").map(buf, "ghm", "gh:issue:comments", function()
        require("github.features.comments.list").open_from_list(buf)
      end)
    end
    require("github.core.navigation").map(buf, "ghy", prefix .. "yank", function()
      require("github.features.links.copy").from_list(buf, "issue")
    end)
    require("github.core.navigation").map(buf, "<C-o>", prefix .. "view", function()
      require("github.features.links.open").from_list(buf, "issue")
    end)
    require("github.core.navigation").map(buf, "K", prefix .. "preview", function()
      preview(buf)
    end)
    require("github.core.navigation").map(buf, "<C-j>", prefix .. "select:next", function()
      toggle(buf, 1)
    end)
    require("github.core.navigation").map(buf, "<C-k>", prefix .. "select:prev", function()
      toggle(buf, -1)
    end)
  end
  M.search(buf, state.condition)
end
function M.clear_selection(buf)
  if states[buf] and vim.api.nvim_buf_is_loaded(buf) then
    states[buf].selected = {}
    render(buf, states[buf])
  end
end
function M.state(buf)
  return states[buf]
end
return M
