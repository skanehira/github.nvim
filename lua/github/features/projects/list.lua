local M = {}

local float = require("github.core.float")
local ui = require("github.features.projects.ui")

local HOST = "github.com"
local states = {}
local resized = false

local function reason(err)
  if type(err) == "table" and type(err.reason) == "string" then
    return err.reason
  end
  return tostring(err)
end

local function notify_error(message)
  vim.notify("GitHub projects: " .. message, vim.log.levels.ERROR)
end

local function screen_name(owner)
  return "projects-list:" .. HOST .. ":" .. owner
end

local function win_for(buf)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
    end
  end
end

local function type_name(type)
  return type == "User" and "user" or "organization"
end

local function render(buf)
  local state = states[buf]
  local win = win_for(buf)
  if not state or not win or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local width = vim.api.nvim_win_get_config(win).width
  local header, header_spans = ui.header({
    text = string.format("Projects for %s (%s)  ·  %d open", state.owner, type_name(state.type), #state.projects),
    loading = state.loading,
    error = state.error,
    truncated = state.truncated,
  })
  local lines = { header }
  local spans = {}
  for _, span in ipairs(header_spans) do
    spans[#spans + 1] = span
  end
  if not state.loading and #state.projects == 0 then
    lines[2] = "No open projects"
  end
  for index, project in ipairs(state.projects) do
    local prefix = "#" .. project.number .. " "
    local suffix = "  " .. project.item_count .. " items  " .. (project.public and "public" or "private")
    local title_width = math.max(1, width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix))
    local row = ui.truncate(prefix .. ui.truncate(project.title, title_width) .. suffix, width)
    lines[#lines + 1] = row
    if index == state.selected then
      spans[#spans + 1] = { #lines - 1, 0, #row, "GitHubProjectsCardSelected" }
    end
  end
  ui.set_lines(buf, lines)
  ui.apply(buf, spans)
  local cursor = state.selected and state.projects[state.selected] and (state.selected + 1) or 1
  vim.api.nvim_win_set_cursor(win, { cursor, 0 })
end

local function reconcile_selection(state, previous_number, previous_index)
  if #state.projects == 0 then
    state.selected = nil
    return
  end
  if previous_number then
    for index, project in ipairs(state.projects) do
      if project.number == previous_number then
        state.selected = index
        return
      end
    end
  end
  state.selected = math.max(1, math.min(previous_index or 1, #state.projects))
end

local function load(buf)
  local state = states[buf]
  if not state then
    return
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.loading = "Loading projects..."
  state.error = nil
  render(buf)
  local api = require("github.features.projects.api").new()
  api.list_projects({ host = HOST, owner = state.owner, type = state.type }, function(result, err)
    if states[buf] ~= state or state.generation ~= generation or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    state.loading = nil
    if not result then
      state.error = reason(err)
      render(buf)
      return
    end
    local previous_number = state.projects[state.selected] and state.projects[state.selected].number
    local previous_index = state.selected
    state.error = nil
    state.projects = result.projects
    state.truncated = result.truncated and "Showing 100 projects" or nil
    reconcile_selection(state, previous_number, previous_index)
    render(buf)
  end)
end

local function move(buf, delta)
  local state = states[buf]
  if not state or #state.projects == 0 then
    return
  end
  state.selected = math.max(1, math.min(#state.projects, (state.selected or 1) + delta))
  render(buf)
end

local function open_selected(buf)
  local state = states[buf]
  local project = state and state.projects[state.selected]
  if not project then
    return
  end
  require("github.features.projects.board").open({
    owner = { host = HOST, owner = state.owner, type = state.type },
    number = project.number,
    parent_win = win_for(buf),
  })
end

local function ensure_resize_autocmd()
  if resized then
    return
  end
  resized = true
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("github_projects_list", { clear = true }),
    callback = function()
      for buf in pairs(states) do
        render(buf)
      end
    end,
  })
end

local function open_list(resolved, parent_win)
  local name = screen_name(resolved.owner)
  local width, height = float.target_size(0.7, 0.7)
  local win, buf = float.open({ name = name, parent = parent_win, width = width, height = height })
  local state = states[buf]
  if state then
    state.owner, state.type = resolved.owner, resolved.type
    load(buf)
    return
  end
  state = {
    owner = resolved.owner,
    type = resolved.type,
    projects = {},
    selected = 1,
    loading = nil,
    error = nil,
    generation = 0,
    truncated = nil,
  }
  states[buf] = state
  ui.buffer(buf, { readonly = true, filetype = "gh-projects-list" })
  local function close()
    float.close(name)
  end
  ui.keymaps(buf, {
    n = {
      j = function()
        move(buf, vim.v.count1)
      end,
      k = function()
        move(buf, -vim.v.count1)
      end,
      ["<CR>"] = function()
        open_selected(buf)
      end,
      r = function()
        load(buf)
      end,
      q = close,
      ["<Esc>"] = close,
    },
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      states[buf] = nil
    end,
  })
  ensure_resize_autocmd()
  load(buf)
  return win
end

local function attached(tab, parent)
  if not vim.api.nvim_tabpage_is_valid(tab) or vim.api.nvim_get_current_tabpage() ~= tab then
    return false
  end
  if not vim.api.nvim_win_is_valid(parent) then
    return false
  end
  return vim.api.nvim_win_get_tabpage(parent) == tab
end

function M.open(opts)
  opts = opts or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local parent = opts.parent_win or vim.api.nvim_get_current_win()
  local api = require("github.features.projects.api").new()
  api.resolve_owner({ host = HOST, owner = opts.owner }, function(resolved, err)
    if not attached(tab, parent) then
      return
    end
    if not resolved then
      notify_error(reason(err))
      return
    end
    if opts.number then
      require("github.features.projects.board").open({
        owner = resolved,
        number = opts.number,
        parent_win = parent,
      })
      return
    end
    open_list(resolved, parent)
  end)
end

function M.state(buf)
  return states[buf]
end

return M
