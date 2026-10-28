local gh = require("github.core.gh")
local request = require("github.core.request")
local buffer = require("github.core.buffer")
local M, states = {}, {}

local queries = {
  assignees = [[query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) { issue(number: $number) {
    id assignees(first: 100, after: $cursor) { nodes { id login } pageInfo { hasNextPage endCursor } }
  } }
}]],
  labels = [[query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) { issue(number: $number) {
    id labels(first: 100, after: $cursor) { nodes { id name } pageInfo { hasNextPage endCursor } }
  } }
}]],
  assignableUsers = [[query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    assignableUsers(first: 100, after: $cursor) { nodes { id login } pageInfo { hasNextPage endCursor } }
  }
}]],
  availableLabels = [[query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    labels(first: 100, after: $cursor) { nodes { id name } pageInfo { hasNextPage endCursor } }
  }
}]],
}
local mutation = [[mutation($input: UpdateIssueInput!) {
  updateIssue(input: $input) { issue { id } }
}]]
local function notify(state, message, level)
  local reason = type(message) == "table" and message.reason or tostring(message)
  vim.notify(
    "GitHub " .. state.target.owner .. "/" .. state.target.repo .. ": " .. reason,
    level or vim.log.levels.ERROR
  )
end
local function variables(target, cursor)
  return { owner = target.owner, repo = target.repo, number = target.issue_number, cursor = cursor }
end
local function collect(client, state, token, candidate, done)
  local kind = state.kind
  local key = candidate and (kind == "assignees" and "assignableUsers" or "availableLabels") or kind
  local field = candidate and (kind == "assignees" and "assignableUsers" or "labels") or kind
  local id
  gh.paginate(function(cursor, next_page)
    local vars = variables(state.target, cursor)
    if candidate then
      vars.number = nil
    end
    client.graphql(state.target, queries[key], vars, function(data, err)
      if not request.apply(token, function() end, true) then
        return
      end
      local payload = type(data) == "table" and data.data
      local repository = type(payload) == "table" and payload.repository
      repository = type(repository) == "table" and repository or nil
      local issue = repository and repository.issue
      issue = type(issue) == "table" and issue or nil
      local result = candidate and repository and repository[field] or (not candidate and issue and issue[field])
      if not candidate then
        if not issue or type(issue.id) ~= "string" or issue.id == "" or (id and id ~= issue.id) then
          return next_page(nil, err or "invalid issue response")
        end
        id = issue.id
      end
      if type(result) ~= "table" then
        return next_page(nil, err or "invalid attribute response")
      end
      next_page({ items = result.nodes, pageInfo = result.pageInfo })
    end)
  end, function(nodes, err)
    if not nodes then
      return done(nil, err)
    end
    local name = kind == "assignees" and "login" or "name"
    for _, item in ipairs(nodes) do
      if type(item) ~= "table" or type(item[name]) ~= "string" or type(item.id) ~= "string" or item.id == "" then
        return done(nil, "invalid attribute item")
      end
    end
    done(nodes, nil, id)
  end)
end
function M.read(buf, target)
  local existing = states[buf]
  if existing and vim.bo[buf].modified then
    return notify(existing, "Unsaved changes: discard before reloading")
  end
  if existing and existing.save then
    buffer.finish_save(existing.save, false)
  end
  local state = { target = target, kind = target.kind == "issue_assignees" and "assignees" or "labels", ready = false }
  states[buf] = state
  require("github.core.navigation").configure(buf, state.kind == "assignees" and "gh-issues-assignees" or nil)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  local token = request.begin(buf)
  collect(gh.new(), state, token, false, function(nodes, err, id)
    request.apply(token, function()
      if not nodes then
        return notify(state, err)
      end
      local name, lines = state.kind == "assignees" and "login" or "name", {}
      for _, item in ipairs(nodes) do
        lines[#lines + 1] = item[name]
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modified = false
      state.ready, state.id = true, id
      require("github.core.navigation").event(
        buf,
        state.kind == "assignees" and "gh_open_issue_assignees" or "gh_open_issue_labels"
      )
    end)
  end)
end
function M.write(buf)
  local state = states[buf]
  if not state or not state.ready then
    if state then
      notify(state, "Cannot save: attributes not fully loaded")
    end
    return
  end
  if not vim.bo[buf].modified then
    return
  end
  local snapshot, err = buffer.begin_save(buf)
  if not snapshot then
    return notify(state, err)
  end
  state.save = snapshot
  local unload = vim.api.nvim_create_autocmd("BufUnload", {
    buffer = buf,
    once = true,
    callback = function()
      buffer.finish_save(snapshot, false)
      state.save = nil
    end,
  })
  local names, seen = {}, {}
  for _, line in ipairs(snapshot.lines) do
    local key = state.kind == "assignees" and line:lower() or line
    if line ~= "" and not seen[key] then
      seen[key] = true
      names[#names + 1] = line
    end
  end
  if state.kind == "assignees" and #names > 10 then
    buffer.finish_save(snapshot, false)
    state.save = nil
    pcall(vim.api.nvim_del_autocmd, unload)
    return notify(state, "cannot assign more than 10 users")
  end
  local token, client = request.begin(buf, "Saving..."), gh.new()
  local function finished(success, message)
    request.apply(token, function()
      local unchanged = vim.api.nvim_buf_get_changedtick(buf) == snapshot.tick
      pcall(vim.api.nvim_del_autocmd, unload)
      buffer.finish_save(snapshot, success)
      state.save = nil
      if success and unchanged then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, names)
        vim.bo[buf].modified = false
      end
      if message then
        notify(state, message, success and vim.log.levels.INFO or vim.log.levels.ERROR)
      end
    end)
  end
  local function update(ids)
    local key = state.kind == "assignees" and "assigneeIds" or "labelIds"
    client.graphql(state.target, mutation, { input = { id = state.id, [key] = ids } }, function(data, failure)
      local payload = type(data) == "table" and data.data
      local update_result = type(payload) == "table" and payload.updateIssue
      local issue = type(update_result) == "table" and update_result.issue
      if type(issue) ~= "table" or issue.id ~= state.id then
        return finished(false, failure or "invalid update response")
      end
      finished(true, "Attributes saved")
    end)
  end
  if #names == 0 then
    return update({})
  end
  collect(client, state, token, true, function(nodes, failure)
    if not nodes then
      return finished(false, failure)
    end
    local key = state.kind == "assignees" and "login" or "name"
    local by_name, ids = {}, {}
    for _, item in ipairs(nodes) do
      local name = state.kind == "assignees" and item[key]:lower() or item[key]
      by_name[name] = item.id
    end
    for _, name in ipairs(names) do
      local lookup = state.kind == "assignees" and name:lower() or name
      if not by_name[lookup] then
        return finished(false, "Invalid or unavailable " .. state.kind .. ": " .. name)
      end
      ids[#ids + 1] = by_name[lookup]
    end
    update(ids)
  end)
end
function M.open_from_list(buf, kind)
  local state = require("github.features.issues.list").state(buf)
  local item = state and state.items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  local target =
    { kind = "issue_" .. kind, owner = state.target.owner, repo = state.target.repo, issue_number = item.number }
  require("github.core.navigation").open(target)
end
return M
