describe("URI routing in Neovim", function()
  local seen
  before_each(function()
    seen = {}
    package.loaded["github.features.issues.list"] = {
      read = function(buf, target)
        seen[#seen + 1] = target
        vim.bo[buf].buftype = "acwrite"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "loaded" })
        vim.bo[buf].modified = false
      end,
    }
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
  end)
  it("normalizes a supported HTTPS address and leaves other HTTPS handlers intact", function()
    local other = 0
    vim.api.nvim_create_autocmd("BufReadCmd", {
      pattern = "https://example.com/*",
      once = true,
      callback = function(ev)
        other = other + 1
        vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, { "other handler" })
      end,
    })
    vim.cmd("edit https://github.com/alice/project/issues")
    assert.equals("github://alice/project/issues", vim.api.nvim_buf_get_name(0))
    assert.same({ { kind = "issue_list", host = "github.com", owner = "alice", repo = "project" } }, seen)
    vim.cmd("edit https://example.com/test")
    assert.equals(1, other)
    assert.equals("other handler", vim.api.nvim_get_current_line())
  end)
  it("preserves an unsaved canonical buffer and unrelated buffers across windows and another BufAdd handler", function()
    vim.o.hidden = true
    vim.cmd("edit github://alice/project/issues")
    local original = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(original, -1, -1, false, { "unsaved" })
    vim.cmd("vnew")
    local unrelated = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(unrelated, 0, -1, false, { "unrelated" })
    local added = 0
    vim.api.nvim_create_autocmd("BufAdd", {
      pattern = "*",
      callback = function()
        added = added + 1
      end,
    })
    vim.cmd("edit https://github.com/alice/project/issues")
    assert.equals(original, vim.api.nvim_get_current_buf())
    assert.same({ "loaded", "unsaved" }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
    assert.equals(true, vim.bo[original].modified)
    assert.same({ "unrelated" }, vim.api.nvim_buf_get_lines(unrelated, 0, -1, false))
    assert.equals(true, vim.api.nvim_buf_is_valid(unrelated))
    assert.equals(true, added > 0)
  end)
end)

describe("netrw coexistence", function()
  it("routes unrelated HTTPS to netrw without calling it for supported URLs", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local curl = dir .. "/curl"
    local log = dir .. "/calls"
    vim.fn.writefile({
      "#!/bin/sh",
      'printf "called\\n" >> "$GITHUB_TEST_CURL_LOG"',
      'while [ "$#" -gt 0 ]; do',
      '  if [ "$1" = -o ]; then shift; printf "NETRW_BODY\\n" > "$1"; break; fi',
      "  shift",
      "done",
    }, curl)
    vim.fn.setfperm(curl, "rwx------")
    local oldpath = vim.env.PATH
    vim.env.PATH = dir .. ":" .. oldpath
    vim.env.GITHUB_TEST_CURL_LOG = log
    vim.cmd("runtime plugin/netrwPlugin.vim")
    local https_handler = false
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "BufReadCmd", group = "Network" })) do
      if autocmd.pattern == "https://*" then
        https_handler = true
      end
    end
    vim.cmd("runtime plugin/github.lua")
    package.loaded["github.features.issues.list"] = {
      read = function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "github" })
      end,
    }
    vim.cmd("edit https://github.com/test/netrw/issues")
    assert.equals("github", vim.api.nvim_get_current_line())
    assert.equals(0, vim.fn.filereadable(log))
    vim.cmd("edit https://example.com/test")
    if https_handler then
      assert.equals("NETRW_BODY", vim.api.nvim_get_current_line())
      assert.same({ "called" }, vim.fn.readfile(log))
    else
      assert.equals("https://example.com/test", vim.api.nvim_buf_get_name(0))
      assert.equals(0, vim.fn.filereadable(log))
    end
    vim.env.PATH = oldpath
    vim.env.GITHUB_TEST_CURL_LOG = nil
    vim.fn.delete(dir, "rf")
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
  end)
end)

describe("supported URI dispatch", function()
  it("opens all URI and HTTPS forms for their corresponding targets", function()
    local kinds = {
      { "", "issue_list", "github.features.issues.list" },
      { "/new", "issue_create", "github.features.issues.create" },
      { "/42", "issue_edit", "github.features.issues.edit" },
      { "/42/assignees", "issue_assignees", "github.features.issues.attributes" },
      { "/42/labels", "issue_labels", "github.features.issues.attributes" },
      { "/42/comments", "comment_list", "github.features.comments.list" },
      { "/42/comments/new", "comment_create", "github.features.comments.create" },
      { "/42/comments/123", "comment_edit", "github.features.comments.edit" },
    }
    local seen
    for _, item in ipairs(kinds) do
      package.loaded[item[3]] = {
        read = function(buf, target)
          seen = target
          vim.bo[buf].buftype = "nofile"
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { target.kind })
        end,
      }
    end
    vim.cmd("runtime plugin/github.lua")
    for _, item in ipairs(kinds) do
      local first = "github://test/dispatch/issues" .. item[1]
      local second = "https://github.com/test/dispatch/issues" .. item[1]
      vim.cmd("edit " .. first)
      local expected = seen
      assert.equals(item[2], vim.api.nvim_get_current_line())
      assert.equals(item[2], expected.kind)
      vim.cmd("bwipeout!")
      seen = nil
      vim.cmd("edit " .. second)
      assert.same(expected, seen)
      assert.equals(item[2], vim.api.nvim_get_current_line())
      vim.cmd("bwipeout!")
    end
    for _, item in ipairs(kinds) do
      package.loaded[item[3]] = nil
    end
  end)
end)

describe("repository-relative list URIs", function()
  local process = require("github.core.process")
  local old_run, old_notify, runs, notices, seen
  local function resolve_origin(argv, opts, cb)
    runs[#runs + 1] = { argv = argv, cwd = opts.cwd }
    vim.schedule(function()
      cb({ code = 0, stdout = argv[2] == "rev-parse" and "/checkout\n" or "git@github.com:a/r.git\n" })
    end)
  end
  local function current_name()
    return vim.api.nvim_buf_get_name(0)
  end
  local function wait_for_current_name(name)
    assert.is_true(vim.wait(1000, function()
      return current_name() == name
    end, 1))
  end
  local function wait_for_notice()
    assert.is_true(vim.wait(1000, function()
      return #notices > 0
    end, 1))
  end
  local function flush_scheduled()
    local flushed = false
    vim.schedule(function()
      flushed = true
    end)
    assert.is_true(vim.wait(1000, function()
      return flushed
    end, 1))
  end
  before_each(function()
    runs, notices, seen = {}, {}, {}
    old_run, old_notify = process.run, vim.notify
    process.run = resolve_origin
    vim.notify = function(message, level)
      notices[#notices + 1] = { message, level }
    end
    package.loaded["github.features.issues.list"] = {
      read = function(buf, target)
        seen[#seen + 1] = target
        vim.bo[buf].buftype = "acwrite"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "loaded" })
        vim.bo[buf].modified = false
      end,
    }
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    process.run, vim.notify = old_run, old_notify
    vim.cmd("silent! %bwipeout!")
    package.loaded["github.features.issues.list"] = nil
  end)

  for _, case in ipairs({ { "issues", "issue_list" }, { "pulls", "pull_list" } }) do
    it("replaces github://" .. case[1] .. " with the list of the origin repository", function()
      vim.cmd("edit github://" .. case[1])
      wait_for_current_name("github://a/r/" .. case[1])
      assert.equals(-1, vim.fn.bufnr("github://" .. case[1]))
      assert.same({ { kind = case[2], host = "github.com", owner = "a", repo = "r" } }, seen)
      assert.same({
        { argv = { "git", "rev-parse", "--show-toplevel" }, cwd = vim.fn.getcwd() },
        { argv = { "git", "remote", "get-url", "origin" }, cwd = vim.fn.getcwd() },
      }, runs)
      assert.same({}, notices)
    end)
  end
  it("switches to an existing list and keeps its unsaved changes", function()
    vim.cmd("edit github://a/r/issues")
    local existing = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(existing, -1, -1, false, { "unsaved" })
    vim.cmd("enew")
    vim.cmd("edit github://issues")
    wait_for_current_name("github://a/r/issues")
    assert.equals(existing, vim.api.nvim_get_current_buf())
    assert.same({ "loaded", "unsaved" }, vim.api.nvim_buf_get_lines(existing, 0, -1, false))
    assert.equals(true, vim.bo[existing].modified)
    assert.equals(1, #seen)
  end)
  it("reports a resolution failure, keeps an empty read-only buffer, and retries on :edit", function()
    process.run = function(_, _, cb)
      vim.schedule(function()
        cb({ code = 1, stdout = "" })
      end)
    end
    vim.cmd("edit github://issues")
    local placeholder = vim.api.nvim_get_current_buf()
    wait_for_notice()
    assert.same({
      {
        "Cannot resolve repository in " .. vim.fn.getcwd() .. ": cannot determine local repository",
        vim.log.levels.ERROR,
      },
    }, notices)
    assert.equals(placeholder, vim.api.nvim_get_current_buf())
    assert.equals("github://issues", current_name())
    assert.same({ "" }, vim.api.nvim_buf_get_lines(placeholder, 0, -1, false))
    assert.equals(false, vim.bo[placeholder].modifiable)
    process.run = resolve_origin
    vim.cmd("edit")
    wait_for_current_name("github://a/r/issues")
  end)
  it("does not take over the window when the user leaves before resolution finishes", function()
    local finish
    process.run = function(_, _, cb)
      finish = cb
    end
    vim.cmd("edit github://issues")
    local placeholder = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    local work = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(work, 0, -1, false, { "unsaved" })
    assert.equals(false, vim.api.nvim_buf_is_valid(placeholder))
    finish({ code = 0, stdout = "/checkout\n" })
    finish({ code = 0, stdout = "git@github.com:a/r.git\n" })
    flush_scheduled()
    assert.equals(work, vim.api.nvim_get_current_buf())
    assert.same({ "unsaved" }, vim.api.nvim_buf_get_lines(work, 0, -1, false))
    assert.same({}, seen)
    assert.same({}, notices)
  end)
  it("does not report a resolution failure after the user has left", function()
    local finish
    process.run = function(_, _, cb)
      finish = cb
    end
    vim.cmd("edit github://issues")
    local placeholder = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    assert.equals(false, vim.api.nvim_buf_is_valid(placeholder))
    finish({ code = 1, stdout = "" })
    flush_scheduled()
    assert.same({}, notices)
  end)
  it("reports when the resolved list cannot be opened", function()
    package.loaded["github.features.issues.list"] = {
      read = function()
        error("read failed", 0)
      end,
    }
    vim.cmd("edit github://issues")
    wait_for_notice()
    assert.equals(1, #notices)
    local prefix = "Cannot open github://a/r/issues: "
    -- 全文を比べない: 原因文の前後に Neovim が呼び出し位置とスタックトレースを付け、版と実行経路で変わる
    assert.equals(prefix, notices[1][1]:sub(1, #prefix))
    assert.is_truthy(notices[1][1]:find("read failed", 1, true))
    assert.equals(vim.log.levels.ERROR, notices[1][2])
  end)
  it("reports the cwd captured at open after the cwd changes during resolution", function()
    local finish
    process.run = function(_, _, cb)
      finish = cb
    end
    local opened_in = vim.fn.getcwd()
    vim.cmd("edit github://issues")
    vim.fn.chdir(vim.fn.fnamemodify(opened_in, ":h"))
    finish({ code = 1, stdout = "" })
    flush_scheduled()
    vim.fn.chdir(opened_in)
    assert.same({
      { "Cannot resolve repository in " .. opened_in .. ": cannot determine local repository", vim.log.levels.ERROR },
    }, notices)
  end)
  it("does not open the list inside the read autocmd when the runner calls back synchronously", function()
    process.run = function(argv, _, cb)
      cb({ code = 0, stdout = argv[2] == "rev-parse" and "/checkout\n" or "git@github.com:a/r.git\n" })
    end
    vim.cmd("edit github://issues")
    wait_for_current_name("github://a/r/issues")
    assert.same({ "loaded" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("replaces every window showing the unresolved buffer", function()
    vim.cmd("edit github://issues")
    local first = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local second = vim.api.nvim_get_current_win()
    wait_for_current_name("github://a/r/issues")
    assert.equals("github://a/r/issues", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first)))
    assert.equals("github://a/r/issues", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(second)))
    vim.cmd("only")
  end)
  it("keeps the buffer opened before :edit as the alternate buffer", function()
    vim.cmd("enew")
    local before = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(before, vim.fn.tempname())
    vim.cmd("edit github://issues")
    wait_for_current_name("github://a/r/issues")
    assert.equals(before, vim.fn.bufnr("#"))
  end)
  it("treats an owner named issues as an ordinary repository URI", function()
    vim.cmd("edit github://issues/repo/issues")
    assert.equals("github://issues/repo/issues", current_name())
    assert.same({ { kind = "issue_list", host = "github.com", owner = "issues", repo = "repo" } }, seen)
    assert.same({}, runs)
  end)
end)
