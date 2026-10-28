local M = {}
local states = {}
local request = require("github.core.request")
local gh = require("github.core.gh")
local query = [[query($query: String!) {
  search(first: 30, type: ISSUE, query: $query) {
    nodes { ... on Issue { id number title state body url
      repository { name owner { login } }
      comments { totalCount }
      assignees(first: 100) { nodes { login } pageInfo { hasNextPage endCursor } }
      labels(first: 100) { nodes { name } pageInfo { hasNextPage endCursor } }
    } }
  }
}]]
local page_query = [[query($id: ID!, $cursor: String!, $assignees: Boolean!) {
  node(id: $id) { ... on Issue {
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
  local lines = {}
  for i, item in ipairs(state.items) do
    local assignees, labels = {}, {}
    for _, user in ipairs(item.assignees.nodes) do
      assignees[#assignees + 1] = user.login
    end
    for _, label in ipairs(item.labels.nodes) do
      labels[#labels + 1] = label.name
    end
    local text = string.format(
      "#%d [%s] %s | assignees: %s | labels: %s | comments: %d",
      item.number,
      item.state,
      item.title,
      table.concat(assignees, ", "),
      table.concat(labels, ", "),
      item.comments.totalCount
    )
    lines[i] = (state.selected[i] and "* " or "") .. text
  end
  if #lines == 0 then
    lines = { "0 issues" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
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
          page_query,
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
  state.selected = {}
  if state.success then
    render(buf, state)
  end
  local token = request.begin(buf)
  local client = gh.new()
  client.graphql(
    state.target,
    query,
    { query = "repo:" .. state.target.owner .. "/" .. state.target.repo .. " type:issue " .. condition },
    function(data, err)
      request.apply(token, function()
        local function fail(reason)
          notify_error(state, reason)
          if not state.success then
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Issue search failed" })
            vim.bo[buf].modifiable = false
          end
        end
        local nodes = data and data.data and data.data.search and data.data.search.nodes
        if type(nodes) ~= "table" then
          return fail(err or "invalid search response")
        end
        for _, item in ipairs(nodes) do
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
      end)
    end
  )
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
  vim.cmd("vnew")
  local preview_buf = vim.api.nvim_get_current_buf()
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(item.body or "", "\n", { plain = true }))
  vim.bo[preview_buf].modifiable = false
end
function M.read(buf, target)
  local state = states[buf]
  if not state then
    state = { target = target, items = {}, selected = {}, condition = "state:open" }
    states[buf] = state
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
    require("github.features.issues.state").attach(buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.keymap.set("n", "ghs", function()
      vim.ui.input({ prompt = "Search issues: ", default = state.condition }, function(value)
        if value ~= nil then
          M.search(buf, value)
        end
      end)
    end, { buffer = buf })
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
    vim.keymap.set("n", "ght", function()
      edit("title")
    end, { buffer = buf })
    vim.keymap.set("n", "ghe", function()
      edit("body")
    end, { buffer = buf })
    vim.keymap.set("n", "gha", function()
      require("github.features.issues.attributes").open_from_list(buf, "assignees")
    end, { buffer = buf })
    vim.keymap.set("n", "ghl", function()
      require("github.features.issues.attributes").open_from_list(buf, "labels")
    end, { buffer = buf })
    vim.keymap.set("n", "ghm", function()
      require("github.features.comments.list").open_from_list(buf)
    end, { buffer = buf })
    vim.keymap.set("n", "<C-o>", function()
      require("github.features.links.open").from_list(buf, "issue")
    end, { buffer = buf })
    vim.keymap.set("n", "K", function()
      preview(buf)
    end, { buffer = buf })
    vim.keymap.set("n", "<C-j>", function()
      toggle(buf, 1)
    end, { buffer = buf })
    vim.keymap.set("n", "<C-k>", function()
      toggle(buf, -1)
    end, { buffer = buf })
  end
  M.search(buf, state.condition)
end
function M.state(buf)
  return states[buf]
end
return M
