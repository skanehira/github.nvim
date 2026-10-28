local M = {}
local states = {}
local gh = require("github.core.gh")
local buffers = require("github.core.buffer")
local request = require("github.core.request")

local function notify(state, message, level)
  local t = state.target
  vim.notify("GitHub " .. t.owner .. "/" .. t.repo .. " #" .. t.issue_number .. ": " .. message, level)
end

function M.read(buf, target)
  if not states[buf] then
    states[buf] = { target = target }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modified = false
    require("github.core.navigation").event(buf, "gh_open_issue_comment")
  end
end

function M.write(buf)
  local state = states[buf]
  if not state then
    return
  end
  local snapshot, err = buffers.begin_save(buf)
  if not snapshot then
    return notify(state, err, vim.log.levels.WARN)
  end
  local body = table.concat(snapshot.lines, "\n")
  if not body:find("%S") then
    buffers.finish_save(snapshot, false)
    return notify(state, "comment cannot be blank", vim.log.levels.ERROR)
  end
  local t = state.target
  local endpoint = ("repos/%s/%s/issues/%d/comments"):format(t.owner, t.repo, t.issue_number)
  local token = request.begin(buf, "Saving...")
  gh.new().rest(t, "POST", endpoint, { body = body }, function(data, failure)
    local success = type(data) == "table"
      and type(data.id) == "number"
      and data.id > 0
      and type(data.html_url) == "string"
      and data.html_url ~= ""
    buffers.finish_save(snapshot, success)
    request.apply(token, function()
      if not success then
        local reason = failure and failure.reason or "invalid response"
        return notify(state, "posting failed or result unknown: " .. reason, vim.log.levels.ERROR)
      end
      local message = "comment posted: " .. data.html_url
      if vim.api.nvim_buf_get_changedtick(buf) ~= snapshot.tick then
        message = message .. " (only the submitted text was posted; later edits remain unsent)"
      end
      notify(state, message, vim.log.levels.INFO)
      local list = state.list
      if list and vim.api.nvim_buf_is_valid(list) and vim.api.nvim_buf_is_loaded(list) then
        require("github.features.comments.list").refresh(list)
      end
      if not vim.bo[buf].modified then
        vim.api.nvim_buf_delete(buf, { force = false })
      end
    end)
  end)
end

function M.open_from_list(buf)
  local list = require("github.features.comments.list").state(buf)
  if not list then
    return
  end
  local t = list.target
  local target =
    { kind = "comment_create", host = t.host, owner = t.owner, repo = t.repo, issue_number = t.issue_number }
  require("github.core.navigation").open(target, function(draft)
    if states[draft] then
      states[draft].list = buf
    end
  end)
end

return M
