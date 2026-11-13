local M = {}

local float = require("github.core.float")
local ui = require("github.features.projects.ui")
local config = require("github.core.config")

local HOST = "github.com"
local states = {}
local targets = {}
local preview_generations = {}
local open_generations = {}
local resized = false

local HELP_ROWS = {
  { "j", "選択を次へ (一覧・ボード・編集・選択肢)" },
  { "k", "選択を前へ (一覧・ボード・編集・選択肢)" },
  { "<CR>", "開く (一覧: ボード, ボード: Issue/PR/下書き, 編集: 選択肢)" },
  { "h", "ボード: 前の列" },
  { "l", "ボード: 次の列" },
  { "H", "ボード: 先頭の列" },
  { "L", "ボード: 末尾の列" },
  { "g", "ボード: 先頭の項目" },
  { "G", "ボード: 末尾の項目" },
  { "K", "ボード: 本文をプレビュー" },
  { "<C-o>", "ボード: URLをブラウザで開く" },
  { "ghy", "ボード: URLをコピー" },
  { "ghs", "ボード: フィルタ" },
  { "ghe", "ボード: フィールドを編集" },
  { "ghn", "ボード: 項目を追加" },
  { "ghd", "ボード: 項目を削除" },
  { "r", "一覧・ボード: 再取得" },
  { "?", "ヘルプを表示" },
  { "y", "確認: 削除する" },
  { "n", "確認: 中止" },
  { "<C-s>", "本文入力: 下書きを追加" },
  { "<C-c>", "入力: 中止" },
  { "q", "閉じる" },
  { "<Esc>", "閉じる" },
}

local function reason(err)
  if type(err) == "table" and type(err.reason) == "string" then
    return err.reason
  end
  return tostring(err)
end

local function notify_error(message)
  vim.notify("GitHub projects: " .. message, vim.log.levels.ERROR)
end

local function board_name(owner, number)
  return "projects-board:" .. HOST .. ":" .. owner .. ":" .. number
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

local function blank(width)
  return string.rep(" ", width)
end

local function item_index(column, item_id)
  for index, item in ipairs(column.items) do
    if item.id == item_id then
      return index
    end
  end
end

local function column_key(column)
  if column.no_value or not column.key then
    return ""
  end
  return column.key
end

local function build_columns(state)
  local columns = {}
  local group = state.group_field
  if type(group) == "table" and type(group.options) == "table" then
    for _, option in ipairs(group.options) do
      columns[#columns + 1] = { key = option.id, name = option.name, color = option.color, items = {}, count = 0 }
    end
  end
  columns[#columns + 1] = { key = nil, no_value = true, name = "値なし", items = {}, count = 0 }
  local by_key = {}
  for index, column in ipairs(columns) do
    if column.key then
      by_key[column.key] = index
    end
  end
  local no_value = #columns
  for _, item in ipairs(state.items) do
    local target = no_value
    if type(group) == "table" then
      local value = type(item.values) == "table" and item.values[group.id]
      if type(value) == "table" and value.kind == "single_select" then
        local index = by_key[value.option_id or value.value]
        if index then
          target = index
        end
      end
    end
    columns[target].items[#columns[target].items + 1] = item
    columns[target].count = columns[target].count + 1
  end
  return columns
end

local function preserve_offsets(old_columns, old_offsets, columns)
  local previous = {}
  for index, column in ipairs(old_columns or {}) do
    previous[column_key(column)] = old_offsets and old_offsets[index] or 1
  end
  local offsets = {}
  for index, column in ipairs(columns) do
    offsets[index] = math.max(1, math.min(previous[column_key(column)] or 1, math.max(1, #column.items)))
  end
  return offsets
end

local function reconcile_selection(state, item_id, previous_column, previous_index)
  if item_id then
    for column_index, column in ipairs(state.columns) do
      if item_index(column, item_id) then
        state.selected = { column_index = column_index, item_id = item_id }
        return
      end
    end
  end
  local column_index = math.max(1, math.min(previous_column or 1, #state.columns))
  local column = state.columns[column_index]
  local index = math.max(1, math.min(previous_index or 1, #column.items))
  state.selected = {
    column_index = column_index,
    item_id = #column.items > 0 and column.items[index].id or nil,
  }
end

local function rebuild(state, item_id, previous_column, previous_index)
  local old_columns, old_offsets = state.columns, state.offsets
  state.columns = build_columns(state)
  state.offsets = preserve_offsets(old_columns, old_offsets, state.columns)
  reconcile_selection(state, item_id, previous_column, previous_index)
end

local function ui_item(item)
  local content = item.content
  if type(content) ~= "table" then
    return item
  end
  -- The API model uses snake_case totals and sub_issues/related_pulls, while ui.card
  -- expects the GraphQL-shaped names; map them here so neither layer has to know both.
  local function connection(value)
    if type(value) ~= "table" then
      return value
    end
    return { totalCount = value.total_count, nodes = value.nodes }
  end
  return {
    id = item.id,
    type = item.type,
    values = item.values,
    archived = item.archived,
    content = {
      number = content.number,
      title = content.title,
      state = content.state,
      url = content.url,
      repository = content.repository,
      labels = connection(content.labels),
      assignees = connection(content.assignees),
      subIssuesSummary = content.sub_issues,
      closedByPullRequestsReferences = connection(content.related_pulls),
    },
  }
end

local function render_column(column, width, selected, selected_item_id)
  local lines, spans, starts, heights = {}, {}, {}, {}
  for index, item in ipairs(column.items) do
    starts[index] = #lines + 1
    local card, card_spans = ui.card(ui_item(item), width, selected and item.id == selected_item_id)
    heights[index] = #card
    local by_row = {}
    for _, span in ipairs(card_spans) do
      by_row[span[1]] = by_row[span[1]] or {}
      by_row[span[1]][#by_row[span[1]] + 1] = span
    end
    for line_index, line in ipairs(card) do
      lines[#lines + 1] = line
      spans[#lines] = by_row[line_index - 1] or {}
    end
    if index < #column.items then
      lines[#lines + 1] = blank(width)
      spans[#lines] = {}
    end
  end
  if #column.items == 0 then
    lines[1] = ui.pad("—", width)
    spans[1] = {}
  end
  return lines, spans, starts, heights
end

local function ensure_visible(state, width, height)
  local column_index = state.selected.column_index
  local column = state.columns[column_index]
  if not column then
    return
  end
  local offset = math.max(1, math.min(state.offsets[column_index] or 1, math.max(1, #column.items)))
  local selected_index = state.selected.item_id and item_index(column, state.selected.item_id)
  if not selected_index then
    state.offsets[column_index] = offset
    return
  end
  local _, _, starts, heights = render_column(column, width, true, state.selected.item_id)
  local available = math.max(1, height - 2)
  local view_start = starts[offset] or 1
  local card_start = starts[selected_index]
  local card_height = heights[selected_index]
  if card_height > available or card_start < view_start then
    offset = selected_index
  elseif card_start + card_height - 1 > view_start + available - 1 then
    local target = card_start + card_height - available
    offset = #starts
    for index = 1, #starts do
      if starts[index] >= target then
        offset = index
        break
      end
    end
  end
  state.offsets[column_index] = offset
end

local function compose_row(row, cells, cell_spans)
  local line = ""
  local spans = {}
  local offsets = {}
  for index, cell in ipairs(cells) do
    if index > 1 then
      line = line .. "│"
    end
    offsets[index] = #line
    line = line .. cell
    for _, span in ipairs(cell_spans[index] or {}) do
      spans[#spans + 1] = { row, offsets[index] + span[2], offsets[index] + span[3], span[4] }
    end
  end
  return line, spans, offsets
end

local function layout(state, width)
  local column_width = ui.column_width(width, config.projects().column_width)
  local visible = ui.visible_columns(width, column_width)
  local first_col = ui.first_col(state.first_col, visible, state.selected.column_index, #state.columns)
  return column_width, visible, first_col
end

local function render(buf)
  local state = states[buf]
  local target = targets[buf]
  local win = win_for(buf)
  if not state or not target or not win or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win_config = vim.api.nvim_win_get_config(win)
  local width, height = win_config.width, win_config.height
  local column_width, visible, first_col = layout(state, width)
  state.visible, state.first_col = visible, first_col
  ensure_visible(state, column_width, height)

  local loading = state.loading
    and ("Loading " .. #state.items .. "/" .. tostring(state.project.item_count or #state.items) .. "...")
  local parts = { target.owner .. " / " .. tostring(state.project.title or ""), #state.items .. " items" }
  if state.view then
    parts[#parts + 1] = "view: " .. state.view
  end
  parts[#parts + 1] = "filter: " .. (state.filter or "")
  local header, header_spans = ui.header({
    text = ui.join(parts),
    loading = loading,
    error = state.error,
    truncated = state.truncated,
  })
  local lines = { header }
  local spans = {}
  for _, span in ipairs(header_spans) do
    spans[#spans + 1] = span
  end

  local visible_columns = {}
  for index = first_col, math.min(#state.columns, first_col + visible - 1) do
    visible_columns[#visible_columns + 1] = index
  end
  local header_cells, header_cell_spans = {}, {}
  for _, index in ipairs(visible_columns) do
    local line, cell_spans = ui.column_header(state.columns[index], column_width, index == state.selected.column_index)
    header_cells[#header_cells + 1] = line
    header_cell_spans[#header_cell_spans + 1] = cell_spans
  end
  local header_row, header_row_spans, header_offsets = compose_row(1, header_cells, header_cell_spans)
  lines[2] = header_row
  for _, span in ipairs(header_row_spans) do
    spans[#spans + 1] = span
  end

  local selected_column = state.selected.column_index
  local cursor_line = 2
  local cursor_col = header_offsets[selected_column - first_col + 1] or 0
  if #state.items == 0 then
    lines[3] = state.filter ~= "" and "No items match filter" or "No items"
  else
    local available = math.max(1, height - 2)
    local columns_data = {}
    for visible_index, index in ipairs(visible_columns) do
      local column = state.columns[index]
      local column_lines, column_spans, starts =
        render_column(column, column_width, index == selected_column, state.selected.item_id)
      columns_data[visible_index] = {
        lines = column_lines,
        spans = column_spans,
        starts = starts,
        view_start = starts[math.max(1, math.min(state.offsets[index] or 1, math.max(1, #column.items)))] or 1,
      }
    end
    local content_offsets = {}
    for row_index = 1, available do
      local cells, cell_spans = {}, {}
      for visible_index, data in ipairs(columns_data) do
        local line_index = data.view_start + row_index - 1
        cells[visible_index] = data.lines[line_index] or blank(column_width)
        cell_spans[visible_index] = data.spans[line_index] or {}
      end
      local line, row_spans, offsets = compose_row(2 + row_index - 1, cells, cell_spans)
      lines[#lines + 1] = line
      for _, span in ipairs(row_spans) do
        spans[#spans + 1] = span
      end
      content_offsets[row_index] = offsets
    end
    local item_id = state.selected.item_id
    local column = state.columns[selected_column]
    local index = item_id and item_index(column, item_id)
    local data = columns_data[selected_column - first_col + 1]
    if index and data and data.starts[index] then
      local card_start = data.starts[index]
      cursor_line = 2 + (card_start - data.view_start + 1)
      local offsets = content_offsets[cursor_line - 2]
      if offsets then
        cursor_col = offsets[selected_column - first_col + 1] or cursor_col
      end
    end
  end
  ui.set_lines(buf, lines)
  ui.apply(buf, spans)
  cursor_line = math.max(1, math.min(#lines, cursor_line))
  vim.api.nvim_win_set_cursor(win, { cursor_line, cursor_col })
end

local function ensure_resize_autocmd()
  if resized then
    return
  end
  resized = true
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("github_projects_board", { clear = true }),
    callback = function()
      for buf in pairs(states) do
        render(buf)
      end
    end,
  })
end

local function fetch_items(buf, kind, filter)
  local state = states[buf]
  local target = targets[buf]
  if not state or not target then
    return
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.loading = kind
  state.error = nil
  render(buf)
  local api = require("github.features.projects.api").new()
  api.items(
    { host = target.host, owner = target.owner, type = target.type },
    state.project.number,
    filter,
    function(result, err)
      if states[buf] ~= state or state.generation ~= generation or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if not result then
        state.loading = nil
        state.error = reason(err)
        render(buf)
        return
      end
      if kind == "filter" then
        state.filter = filter
        state.view = nil
      end
      state.body_cache = {}
      local previous = state.selected
      local previous_column = previous.column_index
      local previous_index = previous.item_id and item_index(state.columns[previous_column], previous.item_id) or 1
      state.items = {}
      for _, item in ipairs(result.items) do
        if not item.archived then
          state.items[#state.items + 1] = item
        end
      end
      state.loading = nil
      state.error = nil
      state.truncated = result.truncated and ("Showing " .. config.projects().max_items .. " of " .. result.total_count)
        or nil
      rebuild(state, previous.item_id, previous_column, previous_index)
      render(buf)
    end
  )
end

local function move_column(buf, target)
  local state = states[buf]
  if not state then
    return
  end
  target = math.max(1, math.min(#state.columns, target))
  if target == state.selected.column_index then
    return
  end
  local old_column = state.columns[state.selected.column_index]
  local old_index = state.selected.item_id and item_index(old_column, state.selected.item_id) or 1
  local new_column = state.columns[target]
  state.selected.column_index = target
  if #new_column.items == 0 then
    state.selected.item_id = nil
  else
    state.selected.item_id = new_column.items[math.max(1, math.min(old_index, #new_column.items))].id
  end
  render(buf)
end

local function move_item(buf, delta)
  local state = states[buf]
  if not state then
    return
  end
  local column = state.columns[state.selected.column_index]
  if not column or #column.items == 0 then
    return
  end
  local index = state.selected.item_id and item_index(column, state.selected.item_id)
  if not index then
    index = delta > 0 and 0 or #column.items + 1
  end
  index = math.max(1, math.min(#column.items, index + delta))
  state.selected.item_id = column.items[index].id
  render(buf)
end

local function select_item_at(buf, index)
  local state = states[buf]
  if not state then
    return
  end
  local column = state.columns[state.selected.column_index]
  if not column or #column.items == 0 then
    return
  end
  index = math.max(1, math.min(#column.items, index))
  state.selected.item_id = column.items[index].id
  render(buf)
end

local function preview_header(item)
  local content = item.content or {}
  if item.type == "ISSUE" then
    return "Issue #" .. tostring(content.number) .. " " .. tostring(content.title or "")
  elseif item.type == "PULL_REQUEST" then
    return "Pull request #" .. tostring(content.number) .. " " .. tostring(content.title or "")
  elseif item.type == "DRAFT_ISSUE" then
    return "Draft issue " .. tostring(content.title or "")
  end
  return tostring(item.type)
end

local function preview(buf)
  local state = states[buf]
  local item = M.selected_item(buf)
  if not state or not item then
    return
  end
  if item.type == "REDACTED" or type(item.content) ~= "table" then
    notify_error("this item cannot be previewed")
    return
  end
  local win = win_for(buf)
  local name = "projects-preview:" .. item.id
  local header = preview_header(item)
  if item.type == "DRAFT_ISSUE" then
    ui.open_preview({ name = name, parent = win, header = header, body = item.content.body or "" })
    return
  end
  local cached = state.body_cache[item.id]
  if cached then
    ui.open_preview({ name = name, parent = win, header = header, body = cached })
    return
  end
  local screen = ui.open_preview({ name = name, parent = win, header = header, loading = "Loading body..." })
  local generations = preview_generations[buf] or {}
  preview_generations[buf] = generations
  generations[name] = (generations[name] or 0) + 1
  local generation = generations[name]
  local target = targets[buf]
  local api = require("github.features.projects.api").new()
  api.fetch_body(
    { host = target.host, owner = target.owner },
    item.content.repository,
    item.content.number,
    function(result, err)
      if states[buf] ~= state or generations[name] ~= generation or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if not result then
        ui.update_preview(screen, { header = header, error = reason(err) })
        return
      end
      if not ui.update_preview(screen, { header = header, body = result.body }) then
        return
      end
      state.body_cache[item.id] = result.body
    end
  )
end

local function open_url(buf)
  local item = M.selected_item(buf)
  if not item then
    return
  end
  if item.type ~= "ISSUE" and item.type ~= "PULL_REQUEST" then
    notify_error("this item has no URL")
    return
  end
  local url = type(item.content) == "table" and item.content.url
  if type(url) ~= "string" or url == "" then
    notify_error("this item has no URL")
    return
  end
  require("github.features.links.open").open({ url })
end

local function copy_url(buf)
  local item = M.selected_item(buf)
  if not item then
    return
  end
  if item.type ~= "ISSUE" and item.type ~= "PULL_REQUEST" then
    notify_error("this item has no URL")
    return
  end
  local url = type(item.content) == "table" and item.content.url
  if type(url) ~= "string" or url == "" then
    notify_error("this item has no URL")
    return
  end
  require("github.features.links.copy").copy({ url })
end

local function open_item(buf)
  local item = M.selected_item(buf)
  if not item then
    return
  end
  if item.type == "ISSUE" then
    local repository = type(item.content) == "table" and item.content.repository
    local owner, repo
    if type(repository) == "string" then
      owner, repo = repository:match("^([%w%-]+)/([%w_.%-]+)$")
    end
    if not owner then
      notify_error("cannot determine the item repository")
      return
    end
    local uri = "github://" .. owner .. "/" .. repo .. "/issues/" .. tostring(item.content.number)
    vim.cmd("tabnew")
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(uri))
    if not ok then
      notify_error("cannot open " .. uri .. ": " .. tostring(err))
    end
  elseif item.type == "PULL_REQUEST" then
    open_url(buf)
  elseif item.type == "DRAFT_ISSUE" then
    preview(buf)
  else
    notify_error("this item cannot be opened")
  end
end

local function apply_filter(buf, value)
  local state = states[buf]
  if not state or value == state.filter then
    return
  end
  fetch_items(buf, "filter", value)
end

local function edit_filter(buf, name)
  local state = states[buf]
  if not state then
    return
  end
  ui.open_input({
    name = "projects-input:filter:" .. name,
    parent = win_for(buf),
    prompt = "Filter",
    value = state.filter,
    on_submit = function(value, close)
      close()
      apply_filter(buf, value)
    end,
  })
end

local function open_help(buf, name)
  ui.open_help({
    name = "projects-help:" .. name,
    parent = win_for(buf),
    rows = HELP_ROWS,
  })
end

local function delegate(buf, module, method)
  local ok, feature = pcall(require, "github.features.projects." .. module)
  if not ok or type(feature[method]) ~= "function" then
    notify_error(module .. " is not available")
    return
  end
  feature[method](buf)
end

local function close(name)
  float.close(name)
end

local function state_column(buf)
  local state = states[buf]
  return state and state.selected.column_index or 1
end

local function setup_screen(buf, name)
  ui.buffer(buf, { readonly = true, filetype = "gh-projects-board" })
  ui.keymaps(buf, {
    n = {
      h = function()
        move_column(buf, state_column(buf) - vim.v.count1)
      end,
      l = function()
        move_column(buf, state_column(buf) + vim.v.count1)
      end,
      j = function()
        move_item(buf, vim.v.count1)
      end,
      k = function()
        move_item(buf, -vim.v.count1)
      end,
      H = function()
        move_column(buf, 1)
      end,
      L = function()
        local state = states[buf]
        move_column(buf, state and #state.columns or 1)
      end,
      g = function()
        select_item_at(buf, 1)
      end,
      G = function()
        local state = states[buf]
        local column = state and state.columns[state.selected.column_index]
        select_item_at(buf, column and #column.items or 0)
      end,
      K = function()
        preview(buf)
      end,
      ["<CR>"] = function()
        open_item(buf)
      end,
      ["<C-o>"] = function()
        open_url(buf)
      end,
      ghy = function()
        copy_url(buf)
      end,
      ghs = function()
        edit_filter(buf, name)
      end,
      ghe = function()
        delegate(buf, "field_edit", "open")
      end,
      ghn = function()
        delegate(buf, "item_manage", "open_add")
      end,
      ghd = function()
        delegate(buf, "item_manage", "open_delete")
      end,
      r = function()
        M.refresh(buf)
      end,
      ["?"] = function()
        open_help(buf, name)
      end,
      q = function()
        close(name)
      end,
      ["<Esc>"] = function()
        close(name)
      end,
    },
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      states[buf] = nil
      targets[buf] = nil
      preview_generations[buf] = nil
    end,
  })
  ensure_resize_autocmd()
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
  local resolved = opts.owner
  local number = opts.number
  local name = board_name(resolved.owner, number)
  local existing_win, existing_buf = float.focus(name)
  if existing_win and states[existing_buf] then
    fetch_items(existing_buf, "refresh", states[existing_buf].filter)
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local parent = opts.parent_win or vim.api.nvim_get_current_win()
  local key = tostring(tab) .. ":" .. name
  open_generations[key] = (open_generations[key] or 0) + 1
  local generation = open_generations[key]
  local api = require("github.features.projects.api").new()
  api.detail({ host = resolved.host, owner = resolved.owner, type = resolved.type }, number, function(detail, err)
    if open_generations[key] ~= generation or not attached(tab, parent) then
      return
    end
    if not detail then
      notify_error(reason(err))
      return
    end
    if detail.project.closed then
      notify_error("Project #" .. number .. " is closed")
      return
    end
    local width, height = float.target_size(0.9, 0.9)
    local _, buf = float.open({ name = name, parent = parent, width = width, height = height })
    if states[buf] then
      targets[buf] = { host = resolved.host, owner = resolved.owner, type = resolved.type }
      fetch_items(buf, "refresh", states[buf].filter)
      return
    end
    local state = {
      project = detail.project,
      fields = detail.fields,
      group_field = detail.group_field,
      columns = {},
      items = {},
      view = detail.view and detail.view.name or nil,
      filter = detail.filter or "",
      selected = { column_index = 1, item_id = nil },
      offsets = {},
      first_col = 1,
      visible = 1,
      loading = nil,
      error = nil,
      generation = 0,
      truncated = nil,
      body_cache = {},
    }
    state.columns = build_columns(state)
    for index = 1, #state.columns do
      state.offsets[index] = 1
    end
    states[buf] = state
    targets[buf] = { host = resolved.host, owner = resolved.owner, type = resolved.type }
    setup_screen(buf, name)
    fetch_items(buf, "initial", state.filter)
  end)
end

function M.state(buf)
  return states[buf]
end

function M.selected_item(buf)
  local state = states[buf]
  if not state or not state.selected.item_id then
    return nil
  end
  for _, item in ipairs(state.items) do
    if item.id == state.selected.item_id then
      return item
    end
  end
end

function M.update_field(buf, item_id, field_id, value)
  local state = states[buf]
  if not state then
    return
  end
  local item
  for _, candidate in ipairs(state.items) do
    if candidate.id == item_id then
      item = candidate
      break
    end
  end
  if not item then
    return
  end
  local previous = state.selected
  local previous_column = previous.column_index
  local previous_index = previous.item_id and item_index(state.columns[previous_column], previous.item_id) or 1
  item.values = type(item.values) == "table" and item.values or {}
  item.values[field_id] = value
  rebuild(state, previous.item_id == item_id and item_id or previous.item_id, previous_column, previous_index)
  render(buf)
end

function M.add_item(buf, item)
  local state = states[buf]
  if not state or type(item) ~= "table" then
    return
  end
  local previous = state.selected
  local previous_column = previous.column_index
  local previous_index = previous.item_id and item_index(state.columns[previous_column], previous.item_id) or 1
  state.items[#state.items + 1] = item
  rebuild(state, item.id, previous_column, previous_index)
  render(buf)
end

function M.remove_item(buf, item_id)
  local state = states[buf]
  if not state then
    return
  end
  local removed = false
  for index = #state.items, 1, -1 do
    if state.items[index].id == item_id then
      table.remove(state.items, index)
      removed = true
      break
    end
  end
  if not removed then
    return
  end
  local previous = state.selected
  local previous_column = previous.column_index
  local previous_index = previous.item_id and item_index(state.columns[previous_column], previous.item_id) or 1
  rebuild(state, previous.item_id == item_id and nil or previous.item_id, previous_column, previous_index)
  render(buf)
end

function M.select_item(buf, item_id)
  local state = states[buf]
  if not state then
    return
  end
  for column_index, column in ipairs(state.columns) do
    if item_index(column, item_id) then
      state.selected = { column_index = column_index, item_id = item_id }
      render(buf)
      return
    end
  end
end

function M.refresh(buf)
  local state = states[buf]
  if not state then
    return
  end
  fetch_items(buf, "refresh", state.filter)
end

return M
