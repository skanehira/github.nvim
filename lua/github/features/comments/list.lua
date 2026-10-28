local M = {}
local states = {}
local request = require("github.core.request")
local gh = require("github.core.gh")

local function render(buf, state)
  local lines, spans = require("github.core.rows").comments(state.items, state.selected)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  require("github.core.highlight").set(buf, spans)
end

function M.refresh(buf)
  local state = states[buf]
  if not state then
    return
  end
  state.selected = {}
  if state.success then
    render(buf, state)
  end
  local token = request.begin(buf)
  local target = state.target
  local endpoint = ("repos/%s/%s/issues/%d/comments?per_page=100"):format(
    target.owner,
    target.repo,
    target.issue_number
  )
  gh.new().rest(target, "GET", endpoint, nil, function(data, err)
    request.apply(token, function()
      if type(data) ~= "table" or not vim.islist(data) then
        local reason = type(err) == "table" and err.reason or "invalid comments response"
        vim.notify("GitHub " .. target.owner .. "/" .. target.repo .. ": " .. reason, vim.log.levels.ERROR)
        if not state.success then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Comment search failed" })
          vim.bo[buf].modifiable = false
        end
        return
      end
      state.items = {}
      for i = 1, math.min(100, #data) do
        state.items[i] = data[i]
      end
      state.success = true
      render(buf, state)
    end)
  end)
end

local function toggle(buf, delta)
  local state = states[buf]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if not state.items[row] then
    return
  end
  state.selected[row] = not state.selected[row] or nil
  render(buf, state)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(#state.items, row + delta)), 0 })
end

local function preview(buf)
  local item = states[buf].items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  require("github.core.view").preview(item.body or "")
end

function M.read(buf, target)
  if not states[buf] then
    states[buf] = { target = target, items = {}, selected = {} }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
    require("github.core.navigation").configure(buf, "gh-issues-comments")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    require("github.core.navigation").map(buf, "ghy", "gh:issue:comment:yank", function()
      require("github.features.links.copy").from_list(buf, "comment")
    end)
    require("github.core.navigation").map(buf, "<C-o>", "gh:issue:comment:view", function()
      require("github.features.links.open").from_list(buf, "comment")
    end)
    require("github.core.navigation").map(buf, "ghn", "gh:issue:comment:new", function()
      require("github.features.comments.create").open_from_list(buf)
    end)
    require("github.core.navigation").map(buf, "ghe", "gh:issue:comment:edit", function()
      require("github.features.comments.edit").open_from_list(buf)
    end)
    require("github.core.navigation").map(buf, "K", "gh:issue:comment:preview", function()
      preview(buf)
    end)
    require("github.core.navigation").map(buf, "<C-j>", "gh:issue:comment:select:next", function()
      toggle(buf, 1)
    end)
    require("github.core.navigation").map(buf, "<C-k>", "gh:issue:comment:select:prev", function()
      toggle(buf, -1)
    end)
  end
  M.refresh(buf)
end

function M.open_from_list(buf)
  local state = require("github.features.issues.list").state(buf)
  local item = state and state.items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  local target = {
    kind = "comment_list",
    host = state.target.host,
    owner = state.target.owner,
    repo = state.target.repo,
    issue_number = item.number,
  }
  require("github.core.navigation").open(target)
end

function M.clear_selection(buf)
  if states[buf] and vim.api.nvim_buf_is_loaded(buf) then
    states[buf].selected = {}
    render(buf, states[buf])
  end
end
function M.state(buf)
  return states[buf]
end

return M
