local M = {}
local active_search

local function window_for(buf)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == buf then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function display_options(win)
  local buf = vim.api.nvim_win_get_buf(win)
  require("github.core.navigation").configure(buf)
  vim.bo[buf].bufhidden = "wipe"
end

function M.preview(body)
  local source = vim.api.nvim_get_current_win()
  local original = require("github.core.navigation").capture(source)
  local buf = vim.fn.bufnr("github:preview")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "github:preview")
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((body or ""):gsub("\r\n", "\n"), "\n", { plain = true }))
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, silent = true })
  local win = window_for(buf)
  if not win then
    vim.cmd("vnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    require("github.core.navigation").inherit(win, original)
  end
  display_options(win)
  if vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
end

function M.search(source_buf, condition, callback, current_condition)
  local source_win = window_for(source_buf)
  if not source_win or not vim.api.nvim_buf_is_loaded(source_buf) then
    return
  end
  if active_search then
    if
      active_search.source == source_buf
      and active_search.valid
      and vim.api.nvim_win_is_valid(active_search.win)
      and vim.api.nvim_win_get_tabpage(active_search.win) == vim.api.nvim_get_current_tabpage()
    then
      active_search.source_win = source_win
      active_search.callback = callback
      active_search.condition = condition
      active_search.current_condition = current_condition
      vim.api.nvim_set_current_win(active_search.win)
      vim.cmd("startinsert!")
      return
    end
    active_search.finish(nil)
  end
  vim.api.nvim_set_current_win(source_win)
  local original = require("github.core.navigation").capture(source_win)
  vim.cmd("botright 1new")
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  require("github.core.navigation").inherit(win, original)
  vim.api.nvim_buf_set_name(buf, "github:issues-search")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "issue-search"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { condition })
  vim.bo[buf].modified = false
  display_options(win)
  local session = {
    valid = true,
    finished = false,
    source = source_buf,
    source_win = source_win,
    callback = callback,
    condition = condition,
    current_condition = current_condition,
    win = win,
  }
  local invalidation = vim.api.nvim_create_autocmd("BufUnload", {
    buffer = source_buf,
    once = true,
    callback = function()
      session.valid = false
    end,
  })
  local function finish(value)
    if session.finished then
      return
    end
    session.finished = true
    if active_search == session then
      active_search = nil
    end
    pcall(vim.api.nvim_del_autocmd, invalidation)
    vim.cmd("stopinsert")
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if not session.valid or not vim.api.nvim_buf_is_loaded(source_buf) then
      return
    end
    if
      not vim.api.nvim_win_is_valid(session.source_win) or vim.api.nvim_win_get_buf(session.source_win) ~= source_buf
    then
      return
    end
    vim.api.nvim_set_current_win(session.source_win)
    local latest = session.current_condition and session.current_condition() or session.condition
    if value == "" or value == latest then
      value = nil
    end
    session.callback(value)
  end
  session.finish = finish
  active_search = session
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if not session.finished then
        vim.schedule(function()
          finish(nil)
        end)
      end
    end,
  })
  local function submit()
    if not session.finished and vim.api.nvim_buf_is_valid(buf) then
      finish(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    end
  end
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    vim.schedule(submit)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function()
    finish(nil)
  end, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    vim.schedule(function()
      finish(nil)
    end)
  end, { buffer = buf, silent = true })
  vim.api.nvim_exec_autocmds("User", { pattern = "gh_open_issue_search", modeline = false })
  vim.api.nvim_win_set_cursor(win, { 1, #condition })
  vim.cmd("startinsert!")
end

return M
