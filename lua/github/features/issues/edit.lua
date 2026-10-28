local M = {}
local gh = require("github.core.gh")
local request = require("github.core.request")
local buffers = require("github.core.buffer")
local states = {}
local read_query = [[query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { id title body } }
}]]
local update_query = [[mutation($input: UpdateIssueInput!) {
  updateIssue(input: $input) { issue { id } }
}]]
local function notify(state, message, level)
  local t = state.target
  vim.notify("GitHub " .. t.owner .. "/" .. t.repo .. " #" .. t.issue_number .. ": " .. message, level)
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
  state.loaded = false
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if field == "body" then
    vim.bo[buf].filetype = "markdown"
  end
  local token = request.begin(buf)
  local variables = { owner = target.owner, repo = target.repo, number = target.issue_number }
  gh.new().graphql(target, read_query, variables, function(data, err)
    request.apply(token, function()
      local result = type(data) == "table" and type(data.data) == "table" and data.data.repository
      local issue = type(result) == "table" and result.issue
      if type(issue) ~= "table" or type(issue.id) ~= "string" or type(issue[field]) ~= "string" then
        return notify(state, err and err.reason or "issue not found or invalid response", vim.log.levels.ERROR)
      end
      state.id, state.loaded = issue.id, true
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.split((issue[field]:gsub("\r\n", "\n")), "\n", { plain = true })
      )
      vim.bo[buf].modified = false
      if field == "body" then
        require("github.core.navigation").event(buf, "gh_open_issue")
      end
    end)
  end)
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
  local text = table.concat(snapshot.lines, "\n")
  if state.field == "title" and (#snapshot.lines ~= 1 or not text:find("%S")) then
    buffers.finish_save(snapshot, false)
    return notify(state, "title must be one nonblank line", vim.log.levels.ERROR)
  end
  local input = { id = state.id }
  input[state.field] = text
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
      notify(state, state.field .. " saved", vim.log.levels.INFO)
      if state.field == "title" and not vim.bo[buf].modified then
        vim.api.nvim_buf_delete(buf, { force = false })
      end
    end)
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
