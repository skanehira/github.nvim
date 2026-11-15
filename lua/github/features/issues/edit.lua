local M = {}

local gh = require("github.core.gh")
local request = require("github.core.request")
local buffers = require("github.core.buffer")
local detail = require("github.features.issues.detail")
local header = require("github.features.issues.header")
local fields = require("github.features.issues.fields")

local states = {}

local title_query = [[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { id title } }
}]]
local body_query = [[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      id
      number
      title
      state
      body
      assignees(first: 100) { nodes { login } }
      labels(first: 100) { totalCount nodes { name color } }
      %s
    }
  }
}]]
local projects_fragment = [[projectItems(first: 10) {
        nodes {
          id
          project { id title }
          fieldValues(first: 50) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
                field { ... on ProjectV2FieldCommon { id name } }
              }
            }
          }
        }
      }]]
local update_query = [[mutation($input: UpdateIssueInput!) {
  updateIssue(input: $input) { issue { id } }
}]]

local function notify(state, message, level)
  local t = state.target
  vim.notify("GitHub " .. t.owner .. "/" .. t.repo .. " #" .. t.issue_number .. ": " .. message, level)
end

local function project_scope_error(err)
  if type(err) ~= "table" or type(err.errors) ~= "table" then
    return false
  end
  for _, message in ipairs(err.errors) do
    if type(message) == "string" and message:lower():find("project", 1, true) then
      return true
    end
  end
  return false
end

local function parallel(tasks, callback)
  if #tasks == 0 then
    return callback({})
  end
  local errors = {}
  local remaining = #tasks
  for index, task in ipairs(tasks) do
    task(function(ok, err)
      if not ok then
        errors[index] = err
      end
      remaining = remaining - 1
      if remaining == 0 then
        callback(errors)
      end
    end)
  end
end

local function unique(list, lower)
  local seen, result = {}, {}
  for _, value in ipairs(list) do
    local key = lower and value:lower() or value
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = key
    end
  end
  return result
end

local function same_set(a, b, lower)
  local left, right = unique(a, lower), unique(b, lower)
  if #left ~= #right then
    return false
  end
  local seen = {}
  for _, value in ipairs(left) do
    seen[value] = true
  end
  for _, value in ipairs(right) do
    if not seen[value] then
      return false
    end
  end
  return true
end

local function diff(state, parsed)
  local issue = state.issue
  local changes = { any = false }
  if parsed.title ~= detail.title_text(issue.title) then
    changes.title = parsed.title
    changes.any = true
  end
  if parsed.body ~= state.body then
    changes.body = parsed.body
    changes.any = true
  end
  local current_assignees = {}
  for _, node in ipairs((type(issue.assignees) == "table" and issue.assignees.nodes) or {}) do
    current_assignees[#current_assignees + 1] = node.login
  end
  if not same_set(current_assignees, parsed.assignees, true) then
    changes.assignees = parsed.assignees
    changes.any = true
  end
  local current_labels = {}
  for _, node in ipairs((type(issue.labels) == "table" and issue.labels.nodes) or {}) do
    current_labels[#current_labels + 1] = node.name
  end
  if not same_set(current_labels, parsed.labels, false) then
    changes.labels = parsed.labels
    changes.any = true
  end
  return changes
end

local function project_diff(state, parsed)
  local current = {}
  for _, item in ipairs((type(state.issue.projectItems) == "table" and state.issue.projectItems.nodes) or {}) do
    local project = type(item) == "table" and item.project
    local title = type(project) == "table" and project.title or ""
    if title ~= "" then
      local field_name, value = header.status(item)
      current[title] = { item = item, title = title, field = field_name, status = value }
    end
  end
  local adds, removes, updates = {}, {}, {}
  local seen = {}
  for _, entry in ipairs(parsed.projects) do
    if not seen[entry.title] then
      seen[entry.title] = true
      local existing = current[entry.title]
      if not existing then
        adds[#adds + 1] = entry
      elseif entry.field and entry.status ~= nil and entry.status ~= (existing.status or "") then
        updates[#updates + 1] = { entry = entry, current = existing }
      end
    end
  end
  for title, existing in pairs(current) do
    if not seen[title] then
      removes[#removes + 1] = existing
    end
  end
  return { adds = adds, removes = removes, updates = updates, current = current }
end

local function resolve(state, changes, projects, callback)
  local result =
    { assignees = nil, labels = nil, project_items = nil, statuses = {}, add_statuses = {}, add_items = {} }
  local stage2
  local function stage1()
    local tasks = {}
    if changes.assignees then
      tasks[#tasks + 1] = function(finish)
        fields.resolve_assignees(state.target, changes.assignees, function(value, err)
          if not value then
            return finish(nil, err)
          end
          result.assignees = value
          finish(true)
        end)
      end
    end
    if changes.labels then
      tasks[#tasks + 1] = function(finish)
        fields.resolve_labels(state.target, changes.labels, function(value, err)
          if not value then
            return finish(nil, err)
          end
          result.labels = value
          finish(true)
        end)
      end
    end
    if #projects.adds > 0 then
      local titles = {}
      for _, entry in ipairs(projects.adds) do
        titles[#titles + 1] = entry.title
      end
      tasks[#tasks + 1] = function(finish)
        fields.resolve_projects(state.target, titles, function(value, err)
          if not value then
            return finish(nil, err)
          end
          result.project_items = value
          finish(true)
        end)
      end
    end
    for index, update in ipairs(projects.updates) do
      tasks[#tasks + 1] = function(finish)
        local project_id = update.current.item.project.id
        if update.entry.status == "" then
          fields.resolve_field(state.target, project_id, update.entry.field, function(field, err)
            if not field then
              return finish(nil, err)
            end
            result.statuses[index] = { field = field }
            finish(true)
          end)
        else
          fields.resolve_status(state.target, project_id, update.entry.field, update.entry.status, function(value, err)
            if not value then
              return finish(nil, err)
            end
            result.statuses[index] = value
            finish(true)
          end)
        end
      end
    end
    parallel(tasks, function(errors)
      if #errors > 0 then
        return callback(nil, errors[1])
      end
      stage2()
    end)
  end
  stage2 = function()
    local tasks = {}
    for index, entry in ipairs(projects.adds) do
      if entry.field and entry.status and entry.status ~= "" then
        tasks[#tasks + 1] = function(finish)
          local project_id = result.project_items.ids[index]
          fields.resolve_status(state.target, project_id, entry.field, entry.status, function(value, err)
            if not value then
              return finish(nil, err)
            end
            result.add_statuses[index] = value
            finish(true)
          end)
        end
      end
    end
    parallel(tasks, function(errors)
      if #errors > 0 then
        return callback(nil, errors[1])
      end
      callback(result)
    end)
  end
  stage1()
end

local function update_project_item(state, item_id, field_name, field_value)
  local nodes = type(state.issue.projectItems) == "table" and state.issue.projectItems.nodes or {}
  for _, node in ipairs(nodes) do
    if node.id == item_id then
      local values = type(node.fieldValues) == "table" and node.fieldValues.nodes or {}
      local found
      for _, value in ipairs(values) do
        local field = type(value) == "table" and value.field
        if type(field) == "table" and field.name == field_name then
          found = value
          break
        end
      end
      if field_value then
        if not found then
          found = { field = { id = field_value.field.id, name = field_value.field.name } }
          values[#values + 1] = found
        end
        found.name = field_value.option.name
        found.optionId = field_value.option.id
      elseif found then
        for index, value in ipairs(values) do
          if value == found then
            table.remove(values, index)
            break
          end
        end
      end
      node.fieldValues = { nodes = values }
      return
    end
  end
end

local function mutate(state, buf, snapshot, changes, projects, resolved, token)
  local tasks = {}
  local input = { id = state.id }
  local parts = {}
  if changes.title then
    input.title = changes.title
    parts[#parts + 1] = "title"
  end
  if changes.body then
    input.body = changes.body
    parts[#parts + 1] = "body"
  end
  if resolved.assignees then
    input.assigneeIds = resolved.assignees.ids
    parts[#parts + 1] = "assignees"
  end
  if resolved.labels then
    input.labelIds = resolved.labels.ids
    parts[#parts + 1] = "labels"
  end
  if #parts > 0 then
    tasks[#tasks + 1] = function(finish)
      fields.update_issue(state.target, input, function(ok, err)
        if not ok then
          return finish(nil, err)
        end
        if changes.title then
          state.issue.title = changes.title
        end
        if changes.body then
          state.body = changes.body
        end
        if resolved.assignees then
          local nodes = {}
          for _, item in ipairs(resolved.assignees.items) do
            nodes[#nodes + 1] = { login = item.login }
          end
          state.issue.assignees = { nodes = nodes }
        end
        if resolved.labels then
          local nodes = {}
          for _, item in ipairs(resolved.labels.items) do
            nodes[#nodes + 1] = { name = item.name, color = item.color }
          end
          state.issue.labels = { nodes = nodes }
        end
        finish(true)
      end)
    end
  end
  for _, remove in ipairs(projects.removes) do
    tasks[#tasks + 1] = function(finish)
      fields.delete_project_item(state.target, remove.item.project.id, remove.item.id, function(ok, err)
        if not ok then
          return finish(nil, err)
        end
        local nodes = type(state.issue.projectItems) == "table" and state.issue.projectItems.nodes or {}
        for index, node in ipairs(nodes) do
          if node.id == remove.item.id then
            table.remove(nodes, index)
            break
          end
        end
        state.issue.projectItems = { nodes = nodes }
        finish(true)
      end)
    end
  end
  for index, update in ipairs(projects.updates) do
    tasks[#tasks + 1] = function(finish)
      local status = resolved.statuses[index]
      local project_id = update.current.item.project.id
      local item_id = update.current.item.id
      if update.entry.status == "" then
        fields.clear_project_field(state.target, project_id, item_id, status.field.id, function(ok, err)
          if not ok then
            return finish(nil, err)
          end
          update_project_item(state, item_id, status.field.name, nil)
          finish(true)
        end)
      else
        fields.update_project_field(
          state.target,
          project_id,
          item_id,
          status.field.id,
          status.option.id,
          function(ok, err)
            if not ok then
              return finish(nil, err)
            end
            update_project_item(state, item_id, status.field.name, status)
            finish(true)
          end
        )
      end
    end
  end
  for index in ipairs(projects.adds) do
    tasks[#tasks + 1] = function(finish)
      local project_id = resolved.project_items.ids[index]
      local project = resolved.project_items.items[index]
      fields.add_project_item(state.target, project_id, state.id, function(item_id, err)
        if not item_id then
          return finish(nil, err)
        end
        resolved.add_items[index] = item_id
        local status = resolved.add_statuses[index]
        if status then
          fields.update_project_field(
            state.target,
            project_id,
            item_id,
            status.field.id,
            status.option.id,
            function(ok, err2)
              if not ok then
                return finish(nil, err2)
              end
              local nodes = type(state.issue.projectItems) == "table" and state.issue.projectItems.nodes or {}
              nodes[#nodes + 1] = {
                id = item_id,
                project = { id = project_id, title = project.title },
                fieldValues = {
                  nodes = {
                    {
                      name = status.option.name,
                      optionId = status.option.id,
                      field = { id = status.field.id, name = status.field.name },
                    },
                  },
                },
              }
              state.issue.projectItems = { nodes = nodes }
              finish(true)
            end
          )
        else
          local nodes = type(state.issue.projectItems) == "table" and state.issue.projectItems.nodes or {}
          nodes[#nodes + 1] =
            { id = item_id, project = { id = project_id, title = project.title }, fieldValues = { nodes = {} } }
          state.issue.projectItems = { nodes = nodes }
          finish(true)
        end
      end)
    end
  end
  parallel(tasks, function(errors)
    local failure
    for _, err in ipairs(errors) do
      if err and not failure then
        failure = err
      end
    end
    local success = failure == nil
    buffers.finish_save(snapshot, success)
    request.apply(token, function()
      if not success then
        return notify(state, failure, vim.log.levels.ERROR)
      end
      notify(state, "saved", vim.log.levels.INFO)
      if not vim.bo[buf].modified then
        detail.render(buf, state.issue, state.target)
      end
    end)
  end)
end

local function read(buf, target, field)
  local state = states[buf]
  if state and vim.bo[buf].modified then
    return notify(state, "unsaved changes retained", vim.log.levels.WARN)
  end
  if not state then
    state = { target = target, field = field, loaded = false }
    states[buf] = state
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
  end
  state.field = field
  state.loaded = false
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if field == "body" then
    vim.bo[buf].filetype = "markdown"
  end
  local token = request.begin(buf)
  local variables = { owner = target.owner, repo = target.repo, number = target.issue_number }
  local function load(query, fallback)
    gh.new().graphql(target, query, variables, function(data, err)
      request.apply(token, function()
        local result = type(data) == "table" and type(data.data) == "table" and data.data.repository
        local issue = type(result) == "table" and result.issue
        if type(issue) ~= "table" or type(issue.id) ~= "string" or type(issue[field]) ~= "string" then
          if field == "body" and not fallback and project_scope_error(err) then
            token = request.begin(buf)
            return load(string.format(body_query, ""), true)
          end
          return notify(state, err and err.reason or "issue not found or invalid response", vim.log.levels.ERROR)
        end
        state.id, state.loaded = issue.id, true
        state.issue = issue
        vim.bo[buf].modifiable = true
        local body = vim.split((issue[field]:gsub("\r\n", "\n")), "\n", { plain = true })
        local lines
        if field == "body" then
          state.body = issue.body:gsub("\r\n", "\n")
          lines = { detail.title_text(issue.title) }
          vim.list_extend(lines, header.lines(issue))
          vim.list_extend(lines, body)
          vim.bo[buf].omnifunc = "v:lua.require'github.features.issues.complete'.omnifunc"
        else
          lines = body
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modified = false
        if field == "body" then
          detail.render(buf, issue, target)
          require("github.core.navigation").event(buf, "gh_open_issue")
        end
      end)
    end)
  end
  load(field == "body" and string.format(body_query, projects_fragment) or title_query, false)
end

function M.state(buf)
  return states[buf]
end

function M.read(buf, target)
  require("github.core.navigation").configure(buf, "markdown")
  for key, destination in pairs({ gha = "issue_assignees", ghl = "issue_labels", ghm = "comment_list" }) do
    local kind = destination
    require("github.core.navigation").map(
      buf,
      key,
      key == "gha" and "gh:issue:assignees" or key == "ghl" and "gh:issue:labels" or "gh:issue:comments",
      function()
        local next_target = vim.deepcopy(target)
        next_target.kind = kind
        require("github.core.navigation").open(next_target)
      end
    )
  end
  require("github.core.navigation").map(buf, "ght", "gh:issue:edit:title", function()
    M.open_title(target)
  end)
  read(buf, target, "body")
end

function M.write(buf)
  local state = states[buf]
  if not state then
    return
  end
  if not state.loaded then
    return notify(state, "issue not loaded", vim.log.levels.ERROR)
  end
  if not vim.bo[buf].modified then
    return
  end
  local snapshot, err = buffers.begin_save(buf)
  if not snapshot then
    return notify(state, err, vim.log.levels.WARN)
  end
  if state.field == "title" then
    local text = table.concat(snapshot.lines, "\n")
    if #snapshot.lines ~= 1 or not text:find("%S") then
      buffers.finish_save(snapshot, false)
      return notify(state, "title must be one nonblank line", vim.log.levels.ERROR)
    end
    local input = { id = state.id, title = text }
    local token = request.begin(buf, "Saving...")
    gh.new().graphql(state.target, update_query, { input = input }, function(data, failure)
      local update = type(data) == "table" and type(data.data) == "table" and data.data.updateIssue
      local result = type(update) == "table" and update.issue
      local success = type(result) == "table" and result.id == state.id
      buffers.finish_save(snapshot, success)
      request.apply(token, function()
        if not success then
          return notify(state, failure and failure.reason or "invalid update response", vim.log.levels.ERROR)
        end
        notify(state, "title saved", vim.log.levels.INFO)
        if not vim.bo[buf].modified then
          vim.api.nvim_buf_delete(buf, { force = false })
        end
      end)
    end)
    return
  end
  local parsed, parse_err = header.parse(snapshot.lines)
  if not parsed then
    buffers.finish_save(snapshot, false)
    return notify(state, parse_err, vim.log.levels.ERROR)
  end
  if not parsed.title:find("%S") then
    buffers.finish_save(snapshot, false)
    return notify(state, "title must be one nonblank line", vim.log.levels.ERROR)
  end
  if #parsed.assignees > 10 then
    buffers.finish_save(snapshot, false)
    return notify(state, "assignees are limited to 10", vim.log.levels.ERROR)
  end
  local changes = diff(state, parsed)
  local projects = project_diff(state, parsed)
  if not changes.any and #projects.adds == 0 and #projects.removes == 0 and #projects.updates == 0 then
    buffers.finish_save(snapshot, true)
    return notify(state, "no changes", vim.log.levels.INFO)
  end
  local token = request.begin(buf, "Saving...")
  resolve(state, changes, projects, function(resolved, resolve_err)
    if not resolved then
      buffers.finish_save(snapshot, false)
      return request.apply(token, function()
        notify(state, resolve_err, vim.log.levels.ERROR)
      end)
    end
    mutate(state, buf, snapshot, changes, projects, resolved, token)
  end)
end

function M.open_body(target)
  require("github.core.navigation").open(target)
end

function M.open_title(target)
  local name = "github.nvim title " .. target.owner .. "/" .. target.repo .. "#" .. target.issue_number
  local buf = vim.fn.bufnr(name)
  local windows = buf ~= -1 and vim.fn.win_findbuf(buf) or {}
  local win
  for _, candidate in ipairs(windows) do
    if vim.api.nvim_win_get_tabpage(candidate) == vim.api.nvim_get_current_tabpage() then
      win = candidate
      break
    end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    local original = require("github.core.navigation").capture(vim.api.nvim_get_current_win())
    vim.cmd("botright 1new")
    require("github.core.navigation").inherit(vim.api.nvim_get_current_win(), original)
    if buf == -1 then
      buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(buf, name)
    else
      vim.api.nvim_set_current_buf(buf)
    end
  end
  require("github.core.navigation").configure(buf)
  if not states[buf] then
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        M.write(buf)
      end,
    })
  end
  read(buf, target, "title")
end

return M
