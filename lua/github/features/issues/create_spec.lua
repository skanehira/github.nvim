local calls, callbacks, notices, choices, old_run, old_notify, old_select
local create
local function respond(i, data)
  callbacks[i]({ code = 0, stdout = vim.json.encode(data) })
end
local function templates()
  return { data = { repository = { issueTemplates = { { name = "Bug", body = "bug body\nline" } } } } }
end
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end
local function set(buf, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
end
local function open(choice)
  vim.cmd("edit github://a/r/issues/new")
  local buf = vim.api.nvim_get_current_buf()
  respond(1, templates())
  choices[1].callback(choices[1].items[choice])
  return buf
end
describe("issue creation", function()
  before_each(function()
    calls, callbacks, notices, choices = {}, {}, {}, {}
    old_run, old_notify, old_select = require("github.core.process").run, vim.notify, vim.ui.select
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1], callbacks[#callbacks + 1] = { argv = argv, opts = opts }, cb
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.ui.select = function(items, opts, cb)
      choices[#choices + 1] = { items = items, opts = opts, callback = cb }
    end
    vim.cmd("runtime plugin/github.lua")
    create = require("github.features.issues.create")
  end)
  after_each(function()
    require("github.core.process").run, vim.notify, vim.ui.select = old_run, old_notify, old_select
    vim.cmd("silent! %bwipeout!")
  end)
  it("lists templates and blank from the URI and inserts the chosen markdown", function()
    local buf = open(2)
    assert.equals("github://a/r/issues/new", vim.api.nvim_buf_get_name(buf))
    assert.equals("markdown", vim.bo[buf].filetype)
    assert.same({ "bug body", "line" }, lines(buf))
    assert.equals("Blank", choices[1].items[1].name)
    local vars = vim.json.decode(calls[1].opts.stdin).variables
    assert.same({ owner = "a", repo = "r" }, vars)
  end)
  it("accepts blank and preserves input on cancellation or template error", function()
    local buf = open(1)
    assert.same({ "" }, lines(buf))
    set(buf, { "draft" })
    local ok = pcall(vim.cmd, "edit github://a/r/issues/new")
    assert.is_false(ok)
    assert.same({ "draft" }, lines(buf))
    create.read(buf, { kind = "issue_create", host = "github.com", owner = "a", repo = "r" })
    assert.same({ "draft" }, lines(buf))
    assert.equals(1, #calls)
  end)
  it("leaves content untouched if fetching templates fails", function()
    vim.cmd("edit github://a/r/issues/new")
    local buf = vim.api.nvim_get_current_buf()
    callbacks[1]({ code = 1, stdout = "", stderr = "" })
    assert.is_true(notices[#notices]:find("failed", 1, true) ~= nil)
    assert.same({ "" }, lines(buf))
  end)
  it("opens from issue list using ghn", function()
    vim.cmd("edit github://a/r/issues")
    respond(1, { data = { search = { nodes = {}, pageInfo = { hasNextPage = false } } } })
    vim.cmd("normal ghn")
    assert.equals("github://a/r/issues/new", vim.api.nvim_buf_get_name(0))
    respond(2, templates())
    assert.equals("Bug", choices[1].items[2].name)
  end)
  it("writes snapshot for the gh terminal, guards duplicate writes and preserves later edits", function()
    local buf = open(1)
    set(buf, { "日本語", 'text "quote"' })
    local started, on_exit, temp = 0, nil, nil
    local old = create.start_terminal
    create.start_terminal = function(argv, cb)
      started, on_exit, temp = started + 1, cb, argv[5]
      assert.same({ "gh", "issue", "create", "-F", temp, "-R", "github.com/a/r" }, argv)
      assert.same({ "日本語", 'text "quote"' }, vim.fn.readfile(temp))
      return true
    end
    vim.cmd("write")
    set(buf, { "日本語", 'text "quote"', "later" })
    vim.cmd("write")
    assert.equals(1, started)
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    on_exit(0, "https://github.com/a/r/issues/42")
    assert.same({ "日本語", 'text "quote"', "later" }, lines(buf))
    assert.is_true(vim.bo[buf].modified)
    assert.equals(0, vim.fn.filereadable(temp))
    assert.is_true(notices[#notices]:find("unsent", 1, true) ~= nil)
    assert.equals(3, #choices[2].items - 1)
    create.start_terminal = old
  end)
  it("runs an actual terminal with a fake gh and exposes all success actions", function()
    local buf = open(1)
    set(buf, { "body", "日本語" })
    local fake = vim.fn.tempname()
    vim.fn.writefile({
      "#!/bin/sh",
      '[ "$1" = issue ] && [ "$2" = create ] && [ "$3" = -F ] && [ "$5" = -R ] && [ "$6" = github.com/a/r ] || exit 2',
      [[test "$(cat "$4")" = "$(printf 'body\n日本語')" || exit 3]],
      'printf "Title: "',
      "read title",
      '[ "$title" = Example ] || exit 4',
      'printf "https://github.com/a/r/issues/42\\n"',
    }, fake)
    vim.fn.setfperm(fake, "rwx------")
    local old, term = create.start_terminal, nil
    create.start_terminal = function(argv, cb)
      argv[1] = fake
      local result = old(argv, cb)
      term = vim.api.nvim_get_current_buf()
      return result
    end
    vim.cmd("write")
    local channel = vim.bo[term].channel
    assert.is_true(#vim.fn.win_findbuf(term) > 0)
    assert.is_true(channel > 0)
    vim.api.nvim_set_current_buf(buf)
    vim.fn.chansend(channel, "Example\n")
    assert.is_true(vim.wait(5000, function()
      return #choices == 2
    end, 20))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_true(notices[#notices]:find("https://github.com/a/r/issues/42", 1, true) ~= nil)
    assert.same({ "Edit", "Copy URL", "Open in browser", "Done" }, choices[2].items)
    local copy = require("github.features.links.copy")
    local old_copy, copied = copy.copy, nil
    copy.copy = function(urls)
      copied = urls
    end
    choices[2].callback("Copy URL")
    assert.same({ "https://github.com/a/r/issues/42" }, copied)
    copy.copy = old_copy
    local browser = require("github.features.links.open")
    local old_open, opened = browser.open, nil
    browser.open = function(urls)
      opened = urls
    end
    choices[2].callback("Open in browser")
    assert.same({ "https://github.com/a/r/issues/42" }, opened)
    browser.open = old_open
    local edit = require("github.features.issues.edit")
    local old_edit, edited = edit.open_body, nil
    edit.open_body = function(target)
      edited = target
    end
    choices[2].callback("Edit")
    assert.equals(42, edited.issue_number)
    assert.equals("a", edited.owner)
    edit.open_body, create.start_terminal = old_edit, old
    vim.fn.delete(fake)
  end)
  it("does not overwrite edits made before choosing a template", function()
    vim.cmd("edit github://a/r/issues/new")
    local buf = vim.api.nvim_get_current_buf()
    respond(1, templates())
    set(buf, { "my draft" })
    choices[1].callback(choices[1].items[2])
    assert.same({ "my draft" }, lines(buf))
    assert.is_true(vim.bo[buf].modified)
    assert.is_true(notices[#notices]:find("retained", 1, true) ~= nil)
  end)
  it("cancels template selection without starting an issue", function()
    vim.cmd("edit github://a/r/issues/new")
    local buf = vim.api.nvim_get_current_buf()
    respond(1, templates())
    choices[1].callback(nil)
    assert.same({ "" }, lines(buf))
    assert.is_true(notices[#notices]:find("cancelled", 1, true) ~= nil)
    assert.equals(1, #calls)
  end)
  it("distinguishes cancellation, failure, and unconfirmed results without retrying", function()
    local buf = open(1)
    set(buf, { "draft", "日本語" })
    local old, callback, started, temp = create.start_terminal, nil, 0, nil
    create.start_terminal = function(argv, cb)
      started = started + 1
      temp = argv[5]
      callback = cb
      return true
    end
    local outcomes = {
      { 130, "", "GitHub a/r: creation cancelled; draft retained" },
      { 1, "", "GitHub a/r: creation failed or result unknown (exit 1); check GitHub before retrying" },
      { 0, "", "GitHub a/r: creation result unknown; check GitHub before retrying" },
      {
        1,
        "https://github.com/a/r/issues/42",
        "GitHub a/r: creation result unknown; check GitHub before retrying: https://github.com/a/r/issues/42",
      },
    }
    for index, outcome in ipairs(outcomes) do
      vim.api.nvim_set_current_buf(buf)
      vim.cmd("write")
      assert.equals(index, started)
      assert.equals(1, vim.fn.filereadable(temp))
      callback(outcome[1], outcome[2])
      assert.same({ "draft", "日本語" }, lines(buf))
      assert.is_true(vim.bo[buf].modified)
      assert.equals(outcome[3], notices[#notices])
      assert.equals(0, vim.fn.filereadable(temp))
      assert.equals(index, started)
      assert.equals(1, #calls)
      assert.equals(1, #choices)
    end
    create.start_terminal = old
  end)
  it("retains the draft and reports a terminal startup failure without retrying", function()
    local buf = open(1)
    set(buf, { "draft", "日本語" })
    local old, started, temp = create.start_terminal, 0, nil
    create.start_terminal = function(argv)
      started = started + 1
      temp = argv[5]
      assert.equals(1, vim.fn.filereadable(temp))
      return false
    end
    vim.cmd("write")
    assert.equals("GitHub a/r: creation failed to start; draft retained", notices[#notices])
    assert.same({ "draft", "日本語" }, lines(buf))
    assert.is_true(vim.bo[buf].modified)
    assert.equals(0, vim.fn.filereadable(temp))
    assert.equals(1, started)
    assert.equals(1, #calls)
    assert.equals(1, #choices)
    create.start_terminal = old
  end)
end)
