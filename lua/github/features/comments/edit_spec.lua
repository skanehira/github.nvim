local calls, pending, notices, old_run, old_notify
local function respond(i, value)
  pending[i]({ code = 0, stdout = vim.json.encode(value) })
end
local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end
local function open()
  vim.cmd("edit github://a/r/issues/7/comments/12")
end
local function comment(body, url)
  return { id = 12, body = body or "old\nbody", issue_url = url or "https://api.github.com/repos/a/r/issues/7" }
end
local function key(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
end
describe("comment editing", function()
  before_each(function()
    calls, pending, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, opts = opts }
      pending[#pending + 1] = cb
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    vim.notify = old_notify
    require("github.core.process").run = old_run
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only!")
    package.loaded["github.features.comments.list"] = nil
  end)
  it("loads the specified comment, sends only its body and reports success", function()
    open()
    assert.same(
      { "gh", "api", "--hostname", "github.com", "--method", "GET", "repos/a/r/issues/comments/12" },
      calls[1].argv
    )
    respond(1, comment())
    assert.same({ "old", "body" }, lines())
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "日本語", "new" })
    vim.cmd("write")
    assert.same(
      { "gh", "api", "--hostname", "github.com", "--method", "PATCH", "repos/a/r/issues/comments/12", "--input", "-" },
      calls[2].argv
    )
    assert.same({ body = "日本語\nnew" }, vim.json.decode(calls[2].opts.stdin))
    respond(2, comment("日本語\nnew"))
    assert.is_false(vim.bo.modified)
    assert.equals("GitHub a/r #7 comment 12: comment saved", notices[#notices])
  end)
  it("opens the current comment only when list selection is clear", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    respond(1, { comment("row") })
    key("<C-j>")
    vim.cmd("normal ghe")
    assert.equals(1, #calls)
    assert.equals("GitHub a/r: clear the selection before editing", notices[#notices])
    key("<C-k>")
    vim.cmd("normal ghe")
    assert.equals("github://a/r/issues/7/comments/12", vim.api.nvim_buf_get_name(0))
    respond(2, comment("from server"))
    assert.same({ "from server" }, lines())
  end)
  it("refuses mismatched issue and failed reads without allowing PATCH", function()
    open()
    respond(1, comment("other", "https://api.github.com/repos/a/r/issues/8"))
    assert.equals("GitHub a/r #7 comment 12: comment issue mismatch", notices[#notices])
    vim.cmd("write")
    assert.equals(1, #calls)
    vim.cmd("edit!")
    pending[2]({ code = 1, stdout = "", stderr = "failure" })
    assert.equals("GitHub a/r #7 comment 12: GitHub request failed (exit 1)", notices[#notices])
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #7 comment 12: comment not loaded", notices[#notices])
  end)
  it("rejects blank input and retains edits during pending or failed saves", function()
    open()
    respond(1, comment())
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "  ", "\t" })
    vim.cmd("write")
    assert.equals(1, #calls)
    assert.equals("GitHub a/r #7 comment 12: comment must not be blank", notices[#notices])
    assert.same({ "  ", "\t" }, lines())
    assert.is_true(vim.bo.modified)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    vim.cmd("write")
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "later" })
    vim.cmd("write")
    assert.equals(2, #calls)
    assert.equals("GitHub a/r #7 comment 12: save already in progress", notices[#notices])
    pending[2]({ code = 1, stdout = "", stderr = "HTTP 403: forbidden" })
    assert.equals("GitHub a/r #7 comment 12: rejected: GitHub request failed (exit 1)", notices[#notices])
    assert.same({ "draft", "later" }, lines())
    assert.is_true(vim.bo.modified)
    vim.cmd("write")
    pending[3]({ code = 1, stdout = "", stderr = "connection reset" })
    assert.equals("GitHub a/r #7 comment 12: result unknown: GitHub request failed (exit 1)", notices[#notices])
    assert.same({ "draft", "later" }, lines())
    assert.is_true(vim.bo.modified)
    assert.equals(3, #calls)
  end)
  it("keeps subsequent changes dirty after success and refuses an unsafe reload", function()
    open()
    respond(1, comment())
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    vim.cmd("write")
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "new" })
    respond(2, comment("draft"))
    assert.is_true(vim.bo.modified)
    local buf = vim.api.nvim_get_current_buf()
    require("github.features.comments.edit").read(
      buf,
      { host = "github.com", owner = "a", repo = "r", issue_number = 7, comment_id = 12 }
    )
    assert.equals(2, #calls)
    assert.same({ "draft", "new" }, lines())
    assert.is_true(vim.bo.modified)
  end)
end)
