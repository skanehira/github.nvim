local M = {}
local states = {}
local request = require("github.core.request")
local gh = require("github.core.gh")
local uri = require("github.core.uri")

local function render(buf, state)
  local lines = {}
  for i, item in ipairs(state.items) do
    local author = type(item.user) == "table" and item.user.login or nil
    local first = (type(item.body) == "string" and item.body or ""):match("^[^\n]*")
    lines[i] = (state.selected[i] and "* " or "") .. (author or "[deleted]") .. ": " .. first
  end
  if #lines == 0 then
    lines = { "0 comments" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
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
  vim.cmd("vnew")
  local preview_buf = vim.api.nvim_get_current_buf()
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(item.body or "", "\n", { plain = true }))
  vim.bo[preview_buf].modifiable = false
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
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.keymap.set("n", "<C-o>", function()
      require("github.features.links.open").from_list(buf, "comment")
    end, { buffer = buf })
    vim.keymap.set("n", "ghn", function()
      require("github.features.comments.create").open_from_list(buf)
    end, { buffer = buf })
    vim.keymap.set("n", "ghe", function()
      require("github.features.comments.edit").open_from_list(buf)
    end, { buffer = buf })
    vim.keymap.set("n", "K", function()
      preview(buf)
    end, { buffer = buf })
    vim.keymap.set("n", "<C-j>", function()
      toggle(buf, 1)
    end, { buffer = buf })
    vim.keymap.set("n", "<C-k>", function()
      toggle(buf, -1)
    end, { buffer = buf })
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
  vim.cmd("edit " .. vim.fn.fnameescape(uri.format(target)))
end

function M.state(buf)
  return states[buf]
end

return M
