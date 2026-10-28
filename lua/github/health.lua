local M = {}

function M.check()
  vim.health.start("github.nvim")
  if vim.fn.executable("gh") == 0 then
    vim.health.error("gh is not installed; install GitHub CLI (https://cli.github.com/)")
    return
  end
  vim.health.ok("gh is installed")
  local ok, result = pcall(function()
    return vim.system({ "gh", "auth", "status", "--hostname", "github.com" }, { text = true, timeout = 10000 }):wait()
  end)
  if ok and result.code == 0 then
    vim.health.ok("gh is authenticated for github.com")
  else
    vim.health.error("gh authentication could not be confirmed; run gh auth status --hostname github.com")
  end
end

return M
