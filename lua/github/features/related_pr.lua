local M = {}
local query = [[
query($owner: String!, $repo: String!, $commit: String!) {
  repository(owner: $owner, name: $repo) {
    object(expression: $commit) {
      __typename
      ... on Commit { associatedPullRequests(first: 1) { nodes { url } } }
    }
  }
}
]]

local function lookup(target, commit, run, notify)
  local name = target.host .. "/" .. target.owner .. "/" .. target.repo
  require("github.core.gh").new(run).graphql(target, query, {
    owner = target.owner,
    repo = target.repo,
    commit = commit,
  }, function(response, err)
    if err then
      return notify(name .. ": " .. err.reason, vim.log.levels.ERROR)
    end
    local data = response.data
    local repository = type(data) == "table" and data.repository
    if type(repository) ~= "table" then
      return notify(name .. ": repository not found or inaccessible", vim.log.levels.ERROR)
    end
    local object = repository.object
    if type(object) ~= "table" or object.__typename ~= "Commit" then
      return notify(name .. ": Commit not found: " .. commit, vim.log.levels.WARN)
    end
    local pulls = object.associatedPullRequests
    if type(pulls) ~= "table" or type(pulls.nodes) ~= "table" then
      return notify(name .. ": invalid associated Pull Request response", vim.log.levels.ERROR)
    end
    local first = pulls.nodes[1]
    if not first then
      return notify(name .. ": no associated Pull Request found for " .. commit, vim.log.levels.INFO)
    end
    if type(first) ~= "table" or type(first.url) ~= "string" or first.url == "" then
      return notify(name .. ": invalid associated Pull Request URL", vim.log.levels.ERROR)
    end
    notify(first.url, vim.log.levels.INFO)
  end)
end

function M.setup(opts)
  opts = opts or {}
  local run = opts.run or require("github.core.process").run
  local notify = opts.notify or vim.notify
  local get_cwd = opts.cwd or vim.fn.getcwd
  vim.api.nvim_create_user_command("GhGetAssociatedPullRequest", function(command)
    local args = command.fargs
    if #args ~= 1 and #args ~= 3 then
      return notify("Usage: GhGetAssociatedPullRequest [owner repo] commit", vim.log.levels.ERROR)
    end
    local repo = require("github.core.repo")
    if #args == 3 then
      local target, err = repo.explicit(args[1], args[2])
      if not target then
        return notify("Invalid repository: " .. err .. "; specify owner repo commit", vim.log.levels.ERROR)
      end
      return lookup(target, args[3], run, notify)
    end
    local cwd = get_cwd()
    repo.resolve(cwd, run, function(target, err)
      if not target then
        return notify("Cannot resolve repository in " .. cwd .. ": " .. err, vim.log.levels.ERROR)
      end
      lookup(target, args[1], run, notify)
    end)
  end, { nargs = "*", force = true })
end

return M
