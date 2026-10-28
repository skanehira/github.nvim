local M = {}
function M.explicit(owner, repo)
  if type(owner) ~= "string" or type(repo) ~= "string" then
    return nil, "invalid repository"
  end
  local target = require("github.core.uri").parse("github://" .. owner .. "/" .. repo .. "/issues")
  if not target then
    return nil, "invalid repository"
  end
  return { host = target.host, owner = target.owner, repo = target.repo }
end
function M.resolve(cwd, run, callback)
  run = run or require("github.core.process").run
  local fixed_cwd = cwd or vim.fn.getcwd()
  run({ "git", "rev-parse", "--show-toplevel" }, { cwd = fixed_cwd }, function(root)
    if not root or root.code ~= 0 then
      return callback(nil, "cannot determine local repository")
    end
    local local_repo = vim.trim(root.stdout)
    run({ "git", "remote", "get-url", "origin" }, { cwd = fixed_cwd }, function(remote)
      if not remote or remote.code ~= 0 then
        return callback(nil, "cannot determine origin")
      end
      local url = vim.trim(remote.stdout)
      local owner, name = url:match("^git@github%.com:([^/]+)/([^/]+)$")
      if not owner then
        owner, name = url:match("^https://github%.com/([^/]+)/([^/]+)$")
      end
      if not owner then
        owner, name = url:match("^ssh://git@github%.com/([^/]+)/([^/]+)$")
      end
      if not owner then
        return callback(nil, "origin is not a github.com repository")
      end
      name = name:gsub("%.git$", "")
      local target = M.explicit(owner, name)
      if not target then
        return callback(nil, "invalid origin repository")
      end
      target.local_repo, target.cwd = local_repo, fixed_cwd
      callback(target)
    end)
  end)
end
return M
