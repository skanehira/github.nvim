local M = {}
local gh = require("github.core.gh")
local request = require("github.core.request")
local buffers = require("github.core.buffer")
local uri = require("github.core.uri")
local states = {}
local query = [[query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) { issueTemplates { name body } }
}]]

local function notify(state, message, level)
  vim.notify("GitHub " .. state.target.owner .. "/" .. state.target.repo .. ": " .. message, level)
end

function M.start_terminal(argv, callback)
  vim.cmd("botright new")
  local term = vim.api.nvim_get_current_buf()
  vim.bo[term].bufhidden = "hide"
  local ok, job = pcall(vim.fn.termopen, argv, {
    on_exit = function(_, code)
      vim.schedule(function()
        local output = ""
        if vim.api.nvim_buf_is_valid(term) and vim.api.nvim_buf_is_loaded(term) then
          output = table.concat(vim.api.nvim_buf_get_lines(term, 0, -1, false), "\n")
        end
        callback(code, output)
        if vim.api.nvim_buf_is_valid(term) then
          vim.api.nvim_buf_delete(term, { force = true })
        end
      end)
    end,
  })
  if not ok or job <= 0 then
    if vim.api.nvim_buf_is_valid(term) then
      vim.api.nvim_buf_delete(term, { force = true })
    end
    return false
  end
  vim.cmd("startinsert")
  return true
end

function M.read(buf, target)
  local state = states[buf]
  if state and vim.bo[buf].modified then
    return notify(state, "unsaved draft retained", vim.log.levels.WARN)
  end
  if not state then
    state = { target = vim.deepcopy(target), ready = false }
    states[buf] = state
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        states[buf] = nil
      end,
    })
  end
  state.ready = false
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  local token = request.begin(buf)
  gh.new().graphql(target, query, { owner = target.owner, repo = target.repo }, function(data, err)
    request.apply(token, function()
      local repo = type(data) == "table" and type(data.data) == "table" and data.data.repository
      local templates = type(repo) == "table" and repo.issueTemplates
      if type(templates) ~= "table" or not vim.islist(templates) then
        return notify(
          state,
          "template fetch failed: " .. (err and err.reason or "invalid response"),
          vim.log.levels.ERROR
        )
      end
      local choices = {}
      for _, item in ipairs(templates) do
        if type(item) == "table" and type(item.name) == "string" and type(item.body) == "string" then
          choices[#choices + 1] = item
        end
      end
      choices[#choices + 1] = { name = "Blank", body = "" }
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      vim.ui.select(choices, {
        prompt = "Choose issue template",
        format_item = function(item)
          return item.name
        end,
      }, function(item)
        request.apply(token, function()
          if not item then
            return notify(state, "template selection cancelled", vim.log.levels.INFO)
          end
          if vim.bo[buf].modified or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
            return notify(state, "unsaved draft retained", vim.log.levels.WARN)
          end
          vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            vim.split((item.body:gsub("\r\n", "\n")), "\n", { plain = true })
          )
          vim.bo[buf].modified = false
          state.ready = true
          require("github.core.navigation").event(buf, "gh_open_issue")
        end)
      end)
    end)
  end)
end

local function next_action(url)
  vim.ui.select(
    { "Edit", "Copy URL", "Open in browser", "Done" },
    { prompt = "Issue created: " .. url },
    function(action)
      if action == "Edit" then
        local target = uri.parse(url)
        if target and target.kind == "issue_edit" then
          require("github.features.issues.edit").open_body(target)
        end
      elseif action == "Copy URL" then
        require("github.features.links.copy").copy({ url })
      elseif action == "Open in browser" then
        require("github.features.links.open").open({ url })
      end
    end
  )
end

function M.write(buf)
  local state = states[buf]
  if not state or not state.ready then
    if state then
      notify(state, "choose a template before saving", vim.log.levels.WARN)
    end
    return
  end
  local snapshot, err = buffers.begin_save(buf)
  if not snapshot then
    return notify(state, err, vim.log.levels.WARN)
  end
  local temp = vim.fn.tempname()
  local ok, written = pcall(vim.fn.writefile, snapshot.lines, temp)
  if not ok or written ~= 0 then
    buffers.finish_save(snapshot, false)
    return notify(state, "cannot write temporary body", vim.log.levels.ERROR)
  end
  local target = state.target
  local argv = { "gh", "issue", "create", "-F", temp, "-R", target.host .. "/" .. target.owner .. "/" .. target.repo }
  local started = M.start_terminal(argv, function(code, output)
    vim.fn.delete(temp)
    local url
    for candidate in output:gmatch("https://github%.com/[%w_.%-]+/[%w_.%-]+/issues/%d+") do
      local parsed = uri.parse(candidate)
      if parsed and parsed.owner:lower() == target.owner:lower() and parsed.repo:lower() == target.repo:lower() then
        url = candidate
      end
    end
    local success = code == 0 and url ~= nil
    local alive = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
    local changed = alive and vim.api.nvim_buf_get_changedtick(buf) ~= snapshot.tick
    buffers.finish_save(snapshot, success)
    if not success then
      if code == 130 and not url then
        return notify(state, "creation cancelled; draft retained", vim.log.levels.WARN)
      end
      if code ~= 0 and not url then
        return notify(
          state,
          "creation failed or result unknown (exit " .. tostring(code) .. "); check GitHub before retrying",
          vim.log.levels.ERROR
        )
      end
      return notify(
        state,
        "creation result unknown; check GitHub before retrying" .. (url and (": " .. url) or ""),
        vim.log.levels.WARN
      )
    end
    local message = "issue created: " .. url
    if changed then
      message = message .. " (only the submitted text was used; later edits remain unsent)"
    end
    notify(state, message, vim.log.levels.INFO)
    if state.list and vim.api.nvim_buf_is_loaded(state.list) then
      require("github.features.issues.list").search(
        state.list,
        require("github.features.issues.list").state(state.list).condition
      )
    end
    if alive and not changed then
      vim.api.nvim_buf_delete(buf, { force = false })
    end
    next_action(url)
  end)
  if not started then
    vim.fn.delete(temp)
    buffers.finish_save(snapshot, false)
    notify(state, "creation failed to start; draft retained", vim.log.levels.ERROR)
  end
end

function M.open_from_list(buf)
  local state = require("github.features.issues.list").state(buf)
  if not state then
    return
  end
  local target = vim.deepcopy(state.target)
  target.kind = "issue_create"
  require("github.core.navigation").open(target, function(draft)
    if states[draft] then
      states[draft].list = buf
    end
  end, "new")
end
return M
