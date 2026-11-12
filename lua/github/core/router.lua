local M = {}
local uri = require("github.core.uri")
local features = {
  pull_list = "github.features.issues.list",
  issue_list = "github.features.issues.list",
  issue_create = "github.features.issues.create",
  issue_edit = "github.features.issues.edit",
  issue_assignees = "github.features.issues.attributes",
  issue_labels = "github.features.issues.attributes",
  comment_list = "github.features.comments.list",
  comment_create = "github.features.comments.create",
  comment_edit = "github.features.comments.edit",
}
local function open_current_repository(buf, target)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  local cwd = vim.fn.getcwd()
  -- schedule_wrap を外さない: run が同期で callback を呼ぶと :edit が nested でない BufReadCmd の中で走り、一覧が読み込まれない
  require("github.core.repo").resolve(
    cwd,
    nil,
    vim.schedule_wrap(function(resolved, err)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if not resolved then
        return vim.notify("Cannot resolve repository in " .. cwd .. ": " .. err, vim.log.levels.ERROR)
      end
      resolved.kind, resolved.issue_number, resolved.comment_id = target.kind, target.issue_number, target.comment_id
      local name = uri.format(resolved)
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local ok, open_err = pcall(vim.api.nvim_win_call, win, function()
          vim.cmd("keepalt edit " .. vim.fn.fnameescape(name))
        end)
        if not ok then
          vim.notify("Cannot open " .. name .. ": " .. tostring(open_err), vim.log.levels.ERROR)
        end
      end
    end)
  )
end
local function dispatch(event, operation)
  local target = uri.parse(vim.api.nvim_buf_get_name(event.buf))
  if not target then
    vim.notify("Unsupported GitHub URI", vim.log.levels.ERROR)
    return
  end
  local ok, feature = pcall(require, features[target.kind])
  if not ok or type(feature[operation]) ~= "function" then
    vim.notify("GitHub feature unavailable: " .. target.kind, vim.log.levels.ERROR)
    return
  end
  if operation == "read" then
    require("github.core.navigation").configure(event.buf)
  end
  feature[operation](event.buf, target)
end
function M.setup()
  local group = vim.api.nvim_create_augroup("github.nvim.router", { clear = true })
  vim.api.nvim_create_autocmd("BufAdd", {
    group = group,
    pattern = "https://github.com/*",
    callback = function(event)
      local target = uri.parse(event.match)
      if not target then
        return
      end
      local name = uri.format(target)
      local existing = vim.fn.bufnr(name)
      if existing == -1 then
        vim.api.nvim_buf_set_name(event.buf, name)
        return
      end
      local windows = vim.fn.win_findbuf(event.buf)
      if vim.bo[event.buf].modified or #windows > 0 then
        vim.notify("Cannot safely reuse GitHub buffer: " .. name, vim.log.levels.ERROR)
        return
      end
      vim.api.nvim_buf_delete(event.buf, { force = false })
      vim.api.nvim_set_current_buf(existing)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "github://*",
    callback = function(event)
      local target = uri.parse_current_repository(vim.api.nvim_buf_get_name(event.buf))
      if target then
        return open_current_repository(event.buf, target)
      end
      dispatch(event, "read")
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "github://*",
    callback = function(event)
      dispatch(event, "write")
    end,
  })
end
return M
