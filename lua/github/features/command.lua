local M = {}

function M.setup(opts)
  opts = opts or {}
  local notify = opts.notify or vim.notify
  local get_cwd = opts.cwd or vim.fn.getcwd
  local generation = 0
  vim.api.nvim_create_user_command("GitHub", function(command)
    local args = command.fargs
    local repo = require("github.core.repo")
    if args[1] == "related-pr" then
      local target
      if #args == 3 then
        local owner, name = args[2]:match("^([^/]+)/([^/]+)$")
        target = repo.explicit(owner, name)
      end
      if (#args ~= 2 and #args ~= 3) or (#args == 3 and not target) then
        return notify("Usage: GitHub related-pr [owner/repo] commit", vim.log.levels.ERROR)
      end
      generation = generation + 1
      return require("github.features.related_pr").get(args[#args], target, {
        run = opts.run,
        notify = notify,
        cwd = get_cwd,
      })
    end
    local target
    if args[2] then
      local owner, name = args[2]:match("^([^/]+)/([^/]+)$")
      target = repo.explicit(owner, name)
    end
    if (args[1] ~= "issues" and args[1] ~= "pulls") or #args > 2 or (args[2] and not target) then
      return notify("Usage: GitHub {issues|pulls} [owner/repo]", vim.log.levels.ERROR)
    end
    generation = generation + 1
    local current = generation
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local function open(destination)
      if
        current ~= generation
        or not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_win_get_buf(win) ~= buf
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      then
        return
      end
      destination.kind = args[1] == "issues" and "issue_list" or "pull_list"
      local name = require("github.core.uri").format(destination)
      local ok, err = pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(name))
      end)
      if not ok then
        notify("Cannot open " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    end
    if target then
      return open(target)
    end
    local cwd = get_cwd()
    repo.resolve(cwd, opts.run, function(resolved, err)
      if current ~= generation then
        return
      end
      if not resolved then
        return notify("Cannot resolve repository in " .. cwd .. ": " .. err, vim.log.levels.ERROR)
      end
      open(resolved)
    end)
  end, { nargs = "*", force = true })
end

return M
