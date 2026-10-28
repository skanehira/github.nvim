local M = {}

function M.available()
  return vim.fn.has("clipboard") == 1
end

function M.write(text)
  if not M.available() then
    return nil, "clipboard provider unavailable"
  end
  local ok, result = pcall(vim.fn.setreg, "+", text, "v")
  if not ok or result ~= 0 then
    return nil, "clipboard write failed"
  end
  return true
end

function M.copy(urls)
  if #urls == 0 then
    vim.notify("No URL selected", vim.log.levels.WARN)
    return
  end
  for _, url in ipairs(urls) do
    if type(url) ~= "string" or not url:match("^https?://") then
      vim.notify("Invalid URL selected", vim.log.levels.ERROR)
      return
    end
  end
  local ok, err = M.write(table.concat(urls, "\n"))
  if not ok then
    vim.notify("Clipboard write failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  vim.notify(("Clipboard write requested for %d URL(s); result unconfirmed"):format(#urls), vim.log.levels.INFO)
end

function M.from_list(buf, kind)
  local list = require("github.features." .. (kind == "issue" and "issues" or "comments") .. ".list")
  local state = list.state(buf)
  if not state then
    return
  end
  local selected = next(state.selected) ~= nil
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local urls = {}
  for index, item in ipairs(state.items) do
    if (selected and state.selected[index]) or (not selected and index == row) then
      urls[#urls + 1] = (kind == "issue" and item.url or item.html_url) or ""
    end
  end
  M.copy(urls)
end

return M
