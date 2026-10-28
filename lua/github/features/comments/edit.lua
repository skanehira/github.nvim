local M = {}
local gh = require("github.core.gh")
local request = require("github.core.request")
local buffers = require("github.core.buffer")
local uri = require("github.core.uri")
local states = {}

local function notify(state, message, level)
  local target = state.target
  vim.notify(
    ("GitHub %s/%s #%d comment %d: %s"):format(
      target.owner,
      target.repo,
      target.issue_number,
      target.comment_id,
      message
    ),
    level
  )
end

local function endpoint(target)
  return ("repos/%s/%s/issues/comments/%d"):format(target.owner, target.repo, target.comment_id)
end

function M.read(buf, target)
  local state = states[buf]
  if state and vim.bo[buf].modified then
    return notify(state, "unsaved changes retained", vim.log.levels.WARN)
  end
  if not state then
    state = { target = target, loaded = false }
    states[buf] = state
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
  end
  state.loaded = false
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  local token = request.begin(buf)
  gh.new().rest(target, "GET", endpoint(target), nil, function(data, err)
    request.apply(token, function()
      if type(data) ~= "table" or type(data.body) ~= "string" or tonumber(data.id) ~= target.comment_id then
        return notify(state, err and err.reason or "invalid comment response", vim.log.levels.ERROR)
      end
      local expected = ("https://api.github.com/repos/%s/%s/issues/%d"):format(
        target.owner,
        target.repo,
        target.issue_number
      )
      if type(data.issue_url) ~= "string" or data.issue_url:lower() ~= expected:lower() then
        return notify(state, "comment issue mismatch", vim.log.levels.ERROR)
      end
      state.loaded = true
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(data.body, "\n", { plain = true }))
      vim.bo[buf].modified = false
    end)
  end)
end

function M.write(buf)
  local state = states[buf]
  if not state then
    return
  end
  if not state.loaded then
    return notify(state, "comment not loaded", vim.log.levels.ERROR)
  end
  local snapshot, err = buffers.begin_save(buf)
  if not snapshot then
    return notify(state, err, vim.log.levels.WARN)
  end
  local body = table.concat(snapshot.lines, "\n")
  if not body:find("%S") then
    buffers.finish_save(snapshot, false)
    return notify(state, "comment must not be blank", vim.log.levels.ERROR)
  end
  local token = request.begin(buf)
  gh.new().rest(state.target, "PATCH", endpoint(state.target), { body = body }, function(data, failure)
    local success = type(data) == "table" and tonumber(data.id) == state.target.comment_id
    buffers.finish_save(snapshot, success)
    request.apply(token, function()
      if not success then
        local kind = failure and failure.kind == "rejected" and "rejected" or "result unknown"
        return notify(state, kind .. ": " .. (failure and failure.reason or "invalid response"), vim.log.levels.ERROR)
      end
      notify(state, "comment saved", vim.log.levels.INFO)
    end)
  end)
end

function M.open_from_list(buf)
  local state = require("github.features.comments.list").state(buf)
  local item = state and state.items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  if next(state.selected) then
    return vim.notify(
      "GitHub " .. state.target.owner .. "/" .. state.target.repo .. ": clear the selection before editing",
      vim.log.levels.WARN
    )
  end
  if type(item.id) ~= "number" or item.id <= 0 or item.id % 1 ~= 0 then
    return vim.notify(
      "GitHub " .. state.target.owner .. "/" .. state.target.repo .. ": invalid comment ID",
      vim.log.levels.ERROR
    )
  end
  local target = {
    kind = "comment_edit",
    host = state.target.host,
    owner = state.target.owner,
    repo = state.target.repo,
    issue_number = state.target.issue_number,
    comment_id = item.id,
  }
  vim.cmd("edit " .. vim.fn.fnameescape(uri.format(target)))
end
return M
