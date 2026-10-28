local calls, callbacks, events, old_run, old_choose, old_notify
local function respond(data)
  callbacks[#callbacks]({ code = 0, stdout = vim.json.encode(data) })
end
local function issue_data(body)
  return { data = { repository = { issue = { id = "I7", title = "Title", body = body or "old\r\nbody" } } } }
end
local function key(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
end

describe("migration behavior from denops-gh", function()
  before_each(function()
    calls, callbacks, events = {}, {}, {}
    old_run = require("github.core.process").run
    old_choose, old_notify = require("github.core.navigation").choose, vim.notify
    require("github.core.process").run = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, input = opts.stdin and vim.json.decode(opts.stdin) }
      callbacks[#callbacks + 1] = callback
    end
    require("github.core.navigation").choose = function(callback)
      callback("new")
    end
    vim.notify = function() end
    vim.cmd("runtime plugin/github.lua")
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("github_parity_test", { clear = true }),
      pattern = "gh_open_issue*",
      callback = function(event)
        events[#events + 1] = { event.match, vim.api.nvim_buf_get_name(0), vim.bo.filetype }
      end,
    })
  end)
  after_each(function()
    require("github.core.process").run = old_run
    require("github.core.navigation").choose = old_choose
    vim.notify = old_notify
    vim.api.nvim_del_augroup_by_name("github_parity_test")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only!")
  end)

  it("normalizes issue text, emits the ready hook and does not save unchanged content", function()
    vim.cmd("edit github://a/r/issues/7")
    respond(issue_data())
    assert.same({ "old", "body" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.same({ { "gh_open_issue", "github://a/r/issues/7", "markdown" } }, events)
    vim.cmd("write")
    assert.equals(1, #calls)
    assert.is_false(vim.bo.modified)
  end)

  for keymap, suffix in pairs({ gha = "assignees", ghl = "labels", ghm = "comments" }) do
    local lhs, path = keymap, suffix
    it("opens " .. path .. " from a dirty issue body using the public Plug action", function()
      vim.cmd("edit github://a/r/issues/7")
      respond(issue_data())
      local original = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved body" })
      local action = ({ gha = "assignees", ghl = "labels", ghm = "comments" })[lhs]
      vim.keymap.set("n", "gx", "<Plug>(gh:issue:" .. action .. ")", { buffer = original, remap = true })
      vim.cmd("normal gx")
      assert.equals("github://a/r/issues/7/" .. path, vim.api.nvim_buf_get_name(0))
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.same({ "unsaved body" }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
      assert.is_true(vim.bo[original].modified)
      if path == "comments" then
        respond({})
        assert.equals("gh-issues-comments", vim.bo.filetype)
      else
        respond({
          data = {
            repository = {
              issue = {
                id = "I7",
                [path] = {
                  nodes = {},
                  pageInfo = { hasNextPage = false },
                },
              },
            },
          },
        })
        assert.equals("gh_open_issue_" .. path, events[#events][1])
        local count = #calls
        vim.cmd("write")
        assert.equals(count, #calls)
      end
    end)
  end

  it("restores ordinary settings when leaving a title opened from an Issue body", function()
    vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
    vim.cmd("edit github://a/r/issues/7")
    respond(issue_data())
    vim.cmd("normal ght")
    respond(issue_data())
    assert.equals(1, vim.api.nvim_win_get_height(0))
    vim.cmd("enew!")
    assert.same({ true, true, true, false }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
  end)
  it("edits titles in a one-line split and closes only the saved title buffer", function()
    vim.cmd("edit github://a/r/issues/7")
    respond(issue_data())
    local body = vim.api.nvim_get_current_buf()
    vim.cmd("normal ght")
    respond(issue_data())
    local title = vim.api.nvim_get_current_buf()
    assert.equals(1, vim.api.nvim_win_get_height(0))
    assert.same({ "Title" }, vim.api.nvim_buf_get_lines(title, 0, -1, false))
    vim.api.nvim_buf_set_lines(title, 0, -1, false, { "New title" })
    vim.cmd("write")
    assert.same({ id = "I7", title = "New title" }, calls[#calls].input.variables.input)
    respond({ data = { updateIssue = { issue = { id = "I7" } } } })
    assert.is_false(vim.api.nvim_buf_is_valid(title))
    assert.equals(body, vim.api.nvim_get_current_buf())
    assert.same({ "old", "body" }, vim.api.nvim_buf_get_lines(body, 0, -1, false))
  end)

  it("normalizes comment CRLF and does not send PATCH when unchanged", function()
    vim.cmd("edit github://a/r/issues/7/comments/12")
    respond({ id = 12, body = "first\r\nsecond", issue_url = "https://api.github.com/repos/a/r/issues/7" })
    assert.same({ "first", "second" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.same({ { "gh_open_issue_comment", "github://a/r/issues/7/comments/12", "markdown" } }, events)
    vim.cmd("write")
    assert.equals(1, #calls)
  end)

  it("matches assignees without case sensitivity and rejects more than ten before fetching candidates", function()
    vim.cmd("edit github://a/r/issues/7/assignees")
    respond({
      data = {
        repository = {
          issue = {
            id = "I7",
            assignees = {
              nodes = {},
              pageInfo = { hasNextPage = false },
            },
          },
        },
      },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "ALICE", "alice" })
    vim.cmd("write")
    respond({
      data = {
        repository = {
          assignableUsers = {
            nodes = { { id = "U1", login = "alice" } },
            pageInfo = { hasNextPage = false },
          },
        },
      },
    })
    assert.same({ id = "I7", assigneeIds = { "U1" } }, calls[#calls].input.variables.input)
    respond({ data = { updateIssue = { issue = { id = "I7" } } } })
    local names = {}
    for i = 1, 11 do
      names[i] = "user" .. i
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, names)
    local count = #calls
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.cmd("write")
    assert.equals(count, #calls)
    assert.same({ "GitHub a/r: cannot assign more than 10 users" }, notices)
    assert.same(names, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_true(vim.bo.modified)
  end)

  for _, kind in ipairs({ "issue", "comment" }) do
    for _, operation in ipairs({ "copy", "open" }) do
      local item_kind, action = kind, operation
      it(
        "clears " .. kind .. " selection after " .. operation .. " and uses only the cursor on the next action",
        function()
          if item_kind == "issue" then
            vim.cmd("edit github://a/r/issues")
            local items = {}
            for i = 1, 2 do
              items[i] = {
                id = "I" .. i,
                number = i,
                title = "title",
                state = "OPEN",
                body = "",
                repository = { name = "r", owner = { login = "a" } },
                url = "https://github.com/a/r/issues/" .. i,
                comments = { totalCount = 0 },
                assignees = { nodes = {}, pageInfo = { hasNextPage = false } },
                labels = { nodes = {}, pageInfo = { hasNextPage = false } },
              }
            end
            respond({ data = { search = { nodes = items } } })
          else
            vim.cmd("edit github://a/r/issues/7/comments")
            respond({
              {
                id = 1,
                body = "first",
                user = { login = "alice" },
                html_url = "https://github.com/a/r/issues/7#issuecomment-1",
              },
              {
                id = 2,
                body = "second",
                user = { login = "bob" },
                html_url = "https://github.com/a/r/issues/7#issuecomment-2",
              },
            })
          end
          local list = require("github.features." .. (item_kind == "issue" and "issues" or "comments") .. ".list")
          local links = require("github.features.links." .. action)
          local old, sent = links[action], {}
          links[action] = function(urls)
            sent[#sent + 1] = urls
          end
          key("<C-j>")
          key("<C-j>")
          links.from_list(vim.api.nvim_get_current_buf(), item_kind)
          assert.same({}, list.state(vim.api.nvim_get_current_buf()).selected)
          links.from_list(vim.api.nvim_get_current_buf(), item_kind)
          links[action] = old
          local prefix = item_kind == "issue" and "https://github.com/a/r/issues/"
            or "https://github.com/a/r/issues/7#issuecomment-"
          assert.same({ { prefix .. "1", prefix .. "2" }, { prefix .. "2" } }, sent)
        end
      )
    end
  end
end)
