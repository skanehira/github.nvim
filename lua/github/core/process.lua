local M = {}
function M.run(argv, opts, callback)
  local fired = false
  local function finish(result, err)
    if fired then
      return
    end
    fired = true
    vim.schedule(function()
      callback(result, err)
    end)
  end
  local ok = pcall(vim.system, argv, {
    cwd = opts.cwd,
    stdin = opts.stdin,
    env = opts.env,
    timeout = opts.timeout,
    text = true,
  }, function(result)
    finish({ code = result.code, signal = result.signal, stdout = result.stdout or "", stderr = result.stderr or "" })
  end)
  if not ok then
    finish(nil, "process failed to start")
  end
end
return M
