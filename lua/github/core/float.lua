local M = {}
local stacks = {}
local initialized = false

local function tab_stack(tab)
  stacks[tab] = stacks[tab] or {}
  return stacks[tab]
end

local function entry_by_name(tab, name)
  for _, entry in ipairs(stacks[tab] or {}) do
    if entry.name == name then
      return entry
    end
  end
end

local function entry_by_win(tab, win)
  for _, entry in ipairs(stacks[tab] or {}) do
    if entry.win == win then
      return entry
    end
  end
end

local function remove_entry(tab, entry)
  local stack = stacks[tab]
  if not stack then
    return
  end
  for index = #stack, 1, -1 do
    if stack[index] == entry then
      table.remove(stack, index)
      return
    end
  end
end

local function descendants(tab, ancestor)
  local result = {}
  for _, entry in ipairs(stacks[tab] or {}) do
    local parent = entry.parent
    while parent do
      if parent == ancestor then
        result[#result + 1] = entry
        break
      end
      local entry_parent = entry_by_win(tab, parent)
      if not entry_parent then
        break
      end
      parent = entry_parent.parent
    end
  end
  return result
end

local function discard(tab, entry)
  if entry.discarded then
    return
  end
  entry.discarded = true
  remove_entry(tab, entry)
  if vim.api.nvim_win_is_valid(entry.win) then
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
end

local function close_descendants(tab, ancestor)
  local children = descendants(tab, ancestor)
  for index = #children, 1, -1 do
    discard(tab, children[index])
  end
end

local function on_window_closed(entry)
  if entry.discarded then
    return
  end
  entry.discarded = true
  remove_entry(entry.tab, entry)
  close_descendants(entry.tab, entry.win)
end

local function valid_in_tab(win, tab)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab
end

local function apply_window_options(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].scrolloff = 0
end

function M.setup()
  if initialized then
    return
  end
  initialized = true
  local group = vim.api.nvim_create_augroup("github_float", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      M.resize_all()
    end,
  })
end

function M.target_size(width_ratio, height_ratio)
  local width = math.max(1, math.floor((vim.o.columns - 2) * width_ratio))
  local height = math.max(1, math.floor((vim.o.lines - 2) * height_ratio))
  return width, height
end

function M.centered(width, height)
  local row = math.max(0, math.floor((vim.o.lines - height - 2) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
  return row, col
end

function M.open(opts)
  assert(type(opts) == "table", "float.open requires options")
  assert(type(opts.name) == "string" and opts.name ~= "", "float.open requires a name")
  M.setup()

  local existing_win, existing_buf = M.focus(opts.name)
  if existing_win then
    return existing_win, existing_buf
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local parent = opts.parent
  if not parent or not vim.api.nvim_win_is_valid(parent) then
    parent = vim.api.nvim_get_current_win()
  end
  local parent_entry = entry_by_win(tab, parent)
  local root = parent_entry and parent_entry.root or parent

  local inner_width = math.max(1, vim.o.columns - 2)
  local inner_height = math.max(1, vim.o.lines - 2)
  local width = opts.width or 1
  local height = opts.height or 1
  local ratio_width = width / inner_width
  local ratio_height
  if not opts.fixed_height then
    ratio_height = height / inner_height
  end

  local row, col
  if opts.row and opts.col then
    row, col = opts.row, opts.col
  else
    row, col = M.centered(width, height)
  end
  row, col = math.max(0, row), math.max(0, col)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = opts.border or "rounded",
    style = opts.style or "minimal",
    focusable = opts.focusable ~= false,
  })
  apply_window_options(win)

  local entry = {
    name = opts.name,
    win = win,
    buf = buf,
    parent = parent,
    root = root,
    tab = tab,
    width = width,
    height = height,
    ratio_width = ratio_width,
    ratio_height = ratio_height,
  }
  tab_stack(tab)[#stacks[tab] + 1] = entry
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      on_window_closed(entry)
    end,
  })
  return win, buf
end

function M.is_open(name)
  local entry = entry_by_name(vim.api.nvim_get_current_tabpage(), name)
  return entry ~= nil and vim.api.nvim_win_is_valid(entry.win)
end

function M.focus(name)
  local tab = vim.api.nvim_get_current_tabpage()
  local entry = entry_by_name(tab, name)
  if not entry or not valid_in_tab(entry.win, tab) then
    return nil
  end
  vim.api.nvim_set_current_win(entry.win)
  return entry.win, entry.buf
end

function M.close(name)
  local tab = vim.api.nvim_get_current_tabpage()
  local entry = entry_by_name(tab, name)
  if not entry then
    return false
  end
  close_descendants(tab, entry.win)
  discard(tab, entry)

  local target
  if valid_in_tab(entry.parent, tab) then
    target = entry.parent
  else
    for index = #tab_stack(tab), 1, -1 do
      if valid_in_tab(stacks[tab][index].win, tab) then
        target = stacks[tab][index].win
        break
      end
    end
  end
  if not target and valid_in_tab(entry.root, tab) then
    target = entry.root
  end
  if target then
    pcall(vim.api.nvim_set_current_win, target)
  end
  return true
end

function M.resize_all()
  for tab, stack in pairs(stacks) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      for _, entry in ipairs(stack) do
        if valid_in_tab(entry.win, tab) then
          local width = math.max(1, math.floor((vim.o.columns - 2) * entry.ratio_width))
          local height = entry.ratio_height and math.max(1, math.floor((vim.o.lines - 2) * entry.ratio_height))
            or entry.height
          local row, col = M.centered(width, height)
          local ok = pcall(vim.api.nvim_win_set_config, entry.win, {
            relative = "editor",
            width = width,
            height = height,
            row = row,
            col = col,
          })
          if ok then
            entry.width, entry.height = width, height
          end
        end
      end
    end
  end
end

return M
