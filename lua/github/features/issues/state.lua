local M = {}
local query = [[mutation($id: ID!, $state: IssueState!) {
  updateIssue(input: {id: $id, state: $state}) { issue { id state } }
}]]

function M.change(buf, desired)
  local list = require("github.features.issues.list")
  local state = list.state(buf)
  if not state then
    return
  end
  local targets = {}
  for row, item in ipairs(state.items) do
    if state.selected[row] then
      targets[#targets + 1] = { number = item.number, id = item.id }
    end
  end
  if #targets == 0 then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local item = state.items[row]
    if item then
      targets[1] = { number = item.number, id = item.id }
    end
  end
  if #targets == 0 then
    vim.notify("No issue selected", vim.log.levels.WARN)
    return
  end
  local progress = require("github.core.progress")
  local token = progress.start(buf, "Saving...")
  local revision = state.revision
  local target = vim.deepcopy(state.target)
  local client = require("github.core.gh").new()
  local i = 1
  local function step()
    if i > #targets then
      progress.finish(token)
      if
        vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_is_loaded(buf)
        and list.state(buf) == state
        and state.revision == revision
      then
        list.search(buf, state.condition)
      end
      return
    end
    local issue = targets[i]
    i = i + 1
    local prefix = ("GitHub %s/%s #%s: "):format(target.owner, target.repo, issue.number)
    if type(issue.id) ~= "string" or issue.id == "" then
      vim.notify(prefix .. "missing issue ID", vim.log.levels.ERROR)
      return step()
    end
    client.graphql(target, query, { id = issue.id, state = desired }, function(data, err)
      local result = data and data.data and data.data.updateIssue and data.data.updateIssue.issue
      if result and result.id == issue.id and result.state == desired then
        vim.notify(prefix .. "success (" .. desired .. ")", vim.log.levels.INFO)
      elseif err and err.reason == "GraphQL errors returned" then
        vim.notify(prefix .. "failed: " .. err.reason, vim.log.levels.ERROR)
      else
        vim.notify(prefix .. "unknown: " .. (err and err.reason or "invalid update response"), vim.log.levels.ERROR)
      end
      step()
    end)
  end
  step()
end

function M.attach(buf)
  for key, desired in pairs({ ghc = "CLOSED", gho = "OPEN" }) do
    require("github.core.navigation").map(
      buf,
      key,
      desired == "CLOSED" and "gh:issue:close" or "gh:issue:open",
      function()
        M.change(buf, desired)
      end
    )
  end
end
return M
