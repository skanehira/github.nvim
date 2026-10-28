local M = {}
local initialized = false
local options = { "number", "relativenumber", "list", "wrap", "cursorline" }
local function window_options(win, managed)
  local saved = vim.w[win].github_window_options
  if managed then
    if not saved then
      saved = {}
      for _, name in ipairs(options) do
        saved[name] = vim.wo[win][name]
      end
      vim.w[win].github_window_options = saved
    end
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].list = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
  elseif saved then
    for _, name in ipairs(options) do
      vim.wo[win][name] = saved[name]
    end
    vim.w[win].github_window_options = nil
  end
end
function M.setup()
  initialized = true
  local group = vim.api.nvim_create_augroup("github_windows", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(event)
      local managed = vim.b[event.buf].github_managed
        or require("github.core.uri").parse(vim.api.nvim_buf_get_name(event.buf)) ~= nil
      window_options(vim.api.nvim_get_current_win(), managed)
    end,
  })
end
function M.capture(win)
  local saved = vim.w[win].github_window_options
  if saved then
    return vim.deepcopy(saved)
  end
  local current = {}
  for _, name in ipairs(options) do
    current[name] = vim.wo[win][name]
  end
  return current
end
function M.inherit(win, saved)
  vim.w[win].github_window_options = vim.deepcopy(saved)
end
function M.configure(buf, filetype)
  if not initialized then
    M.setup()
  end
  vim.b[buf].github_managed = true
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    window_options(win, true)
  end
  if filetype and vim.bo[buf].filetype ~= filetype then
    vim.bo[buf].filetype = filetype
  end
end
function M.event(buf, name)
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_call(buf, function()
      vim.api.nvim_exec_autocmds("User", { pattern = name, modeline = false })
    end)
  end
end
function M.choose(callback)
  vim.ui.select({ "edit", "new", "vnew", "tabnew" }, { prompt = "Open GitHub buffer" }, callback)
end
function M.open(target, after, command)
  local destination = vim.deepcopy(target)
  local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local function open(choice)
    if not vim.tbl_contains({ "edit", "new", "vnew", "tabnew" }, choice) then
      return
    end
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= source then
      return
    end
    vim.api.nvim_set_current_win(win)
    local original = M.capture(win)
    vim.cmd(choice .. " " .. vim.fn.fnameescape(require("github.core.uri").format(destination)))
    if choice ~= "edit" then
      M.inherit(vim.api.nvim_get_current_win(), original)
    end
    if after then
      after(vim.api.nvim_get_current_buf())
    end
  end
  if command then
    open(command)
  else
    M.choose(open)
  end
end
function M.map(buf, key, action, callback)
  local plug = "<Plug>(" .. action .. ")"
  vim.keymap.set("n", plug, callback, { buffer = buf, silent = true })
  vim.keymap.set("n", key, plug, { buffer = buf, silent = true, remap = true })
end
return M
