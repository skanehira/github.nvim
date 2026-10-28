local old_choose
local calls, pending, notices, old_run, old_notify
local function response(i, data)
  pending[i]({ code = 0, stdout = vim.json.encode(data) })
end
local function content(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end
local function set(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end
local function comment()
  return { id = 123, html_url = "https://github.com/a/r/issues/7#issuecomment-123" }
end
describe("comment creation", function()
  before_each(function()
    old_choose = require("github.core.navigation").choose
    require("github.core.navigation").choose = function(callback)
      callback("edit")
    end
    calls, pending, notices = {}, {}, {}
    old_run, old_notify = require("github.core.process").run, vim.notify
    require("github.core.process").run = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, opts = opts }
      pending[#pending + 1] = callback
    end
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.navigation").choose = old_choose
    require("github.core.process").run, vim.notify = old_run, old_notify
    vim.cmd("silent! %bwipeout!")
  end)
  it("opens the direct URI as a markdown draft and posts one snapshot", function()
    vim.cmd("edit github://a/r/issues/7/comments/new")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("markdown", vim.bo.filetype)
    assert.same({ "" }, content())
    set({ "日本語", 'quote "here"' })
    vim.cmd("write")
    assert.same(
      { "gh", "api", "--hostname", "github.com", "--method", "POST", "repos/a/r/issues/7/comments", "--input", "-" },
      calls[1].argv
    )
    assert.same({ body = '日本語\nquote "here"' }, vim.json.decode(calls[1].opts.stdin))
    response(1, comment())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equals("GitHub a/r #7: comment posted: https://github.com/a/r/issues/7#issuecomment-123", notices[#notices])
    assert.equals(1, #calls)
  end)
  it("opens from list and refreshes it independently after success", function()
    vim.cmd("edit github://a/r/issues/7/comments")
    local list = vim.api.nvim_get_current_buf()
    response(1, {})
    vim.cmd("normal ghn")
    assert.equals("github://a/r/issues/7/comments/new", vim.api.nvim_buf_get_name(0))
    set({ "hello" })
    vim.cmd("write")
    response(2, comment())
    assert.equals(3, #calls)
    assert.equals("GET", calls[3].argv[6])
    pending[3]({ code = 1, stdout = "" })
    assert.same({ "0 comments" }, content(list))
    assert.equals(
      "GitHub a/r #7: comment posted: https://github.com/a/r/issues/7#issuecomment-123",
      notices[#notices - 1]
    )
    assert.equals("GitHub a/r: GitHub request failed (exit 1)", notices[#notices])
  end)
  it("rejects blank input without a request", function()
    vim.cmd("edit github://a/r/issues/7/comments/new")
    set({ " \t", "  " })
    vim.cmd("write")
    assert.equals(0, #calls)
    assert.same({ " \t", "  " }, content())
    assert.is_true(vim.bo.modified)
    assert.equals("GitHub a/r #7: comment cannot be blank", notices[#notices])
  end)
  it("keeps text after failed and uncertain requests without retry", function()
    vim.cmd("edit github://a/r/issues/7/comments/new")
    set({ "draft" })
    vim.cmd("write")
    pending[1]({ code = 1, stdout = "" })
    assert.is_true(vim.bo.modified)
    assert.same({ "draft" }, content())
    assert.equals("GitHub a/r #7: posting failed or result unknown: GitHub request failed (exit 1)", notices[#notices])
    assert.equals(1, #calls)
    vim.cmd("write")
    response(2, {})
    assert.is_true(vim.bo.modified)
    assert.equals("GitHub a/r #7: posting failed or result unknown: invalid response", notices[#notices])
    assert.equals(2, #calls)
  end)
  it("blocks duplicate writes and retains edits made while saving", function()
    vim.cmd("edit github://a/r/issues/7/comments/new")
    set({ "draft" })
    vim.cmd("write")
    set({ "draft", "later" })
    vim.cmd("write")
    assert.equals(1, #calls)
    assert.equals("GitHub a/r #7: save already in progress", notices[#notices])
    response(1, comment())
    assert.same({ body = "draft" }, vim.json.decode(calls[1].opts.stdin))
    assert.same({ "draft", "later" }, content())
    assert.is_true(vim.bo.modified)
    assert.equals(1, #calls)
    assert.equals(
      "GitHub a/r #7: comment posted: https://github.com/a/r/issues/7#issuecomment-123"
        .. " (only the submitted text was posted; later edits remain unsent)",
      notices[#notices]
    )
  end)
end)
