local M = {}

local function browser_command(url)
  if vim.fn.has("mac") == 1 then
    return { "open", url }
  elseif vim.fn.has("win32") == 1 then
    return { "rundll32", "url.dll,FileProtocolHandler", url }
  end
  for _, executable in ipairs({ "xdg-open", "wslview", "explorer.exe", "lemonade" }) do
    if vim.fn.executable(executable) == 1 then
      if executable == "lemonade" then
        return { executable, "open", url }
      end
      return { executable, url }
    end
  end
  return nil
end

function M.open(urls)
  local targets = vim.deepcopy(urls)
  if #targets == 0 then
    vim.notify("No URL selected", vim.log.levels.WARN)
    return
  end
  local i = 1
  local function next_url()
    if i > #targets then
      return
    end
    local url = targets[i]
    i = i + 1
    local function failed(reason)
      vim.notify("Failed to open " .. tostring(url) .. ": " .. reason, vim.log.levels.ERROR)
      next_url()
    end
    if type(url) ~= "string" or not url:match("^https?://") then
      return failed("invalid URL")
    end
    local argv = browser_command(url)
    if not argv then
      return failed("no browser handler found")
    end
    require("github.core.process").run(argv, {}, function(result, err)
      if not result then
        return failed(err or "process failed to start")
      end
      if result.code ~= 0 then
        return failed("browser exited with code " .. tostring(result.code))
      end
      next_url()
    end)
  end
  next_url()
end

function M.from_list(buf, kind)
  local list = require("github.features." .. (kind == "issue" and "issues" or "comments") .. ".list")
  local state = list.state(buf)
  if not state then
    return
  end
  local urls = {}
  local selected = next(state.selected) ~= nil
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for index, item in ipairs(state.items) do
    if (selected and state.selected[index]) or (not selected and index == row) then
      urls[#urls + 1] = (kind == "issue" and item.url or item.html_url) or ""
    end
  end
  M.open(urls)
end
return M
