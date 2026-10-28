local old_run, old_notify, calls, notices

describe("plugin setup and readiness", function()
  before_each(function()
    old_run = require("github.core.process").run
    old_notify = vim.notify
    calls, notices = {}, {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.cmd("runtime plugin/github.lua")
  end)
  after_each(function()
    require("github.core.process").run = old_run
    vim.notify = old_notify
    vim.cmd("silent! %bwipeout!")
  end)
  it("starts without external dependencies and reuses the URI entry after repeated setup", function()
    require("github.core.process").run = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, body = vim.json.decode(opts.stdin) }
      cb({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = {} } } }) })
    end
    local blocked = { "telescope", "yaml", "denops" }
    local old_preload = {}
    for _, name in ipairs(blocked) do
      old_preload[name] = package.preload[name]
      package.preload[name] = function()
        error(name .. " must not be required")
      end
    end
    local github = require("github")
    assert.same({}, github.setup())
    assert.same({}, github.setup({}))
    assert.equals(0, #calls)
    vim.cmd("edit github://owner/repo/issues")
    assert.equals("repo:owner/repo type:issue state:open", calls[1].body.variables.query)
    assert.same({ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }, calls[1].argv)
    assert.same({ "0 issues" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(1, #calls)
    for _, name in ipairs(blocked) do
      package.preload[name] = old_preload[name]
    end
  end)
  it("rejects unsupported configuration without disrupting the URI entry", function()
    local github = require("github")
    local ok, err = pcall(github.setup, { unknown = true })
    assert.is_false(ok)
    assert.matches("unknown", err)
    ok, err = pcall(github.setup, "invalid")
    assert.is_false(ok)
    assert.matches("table", err)
    require("github.core.process").run = function(_, _, cb)
      cb({ code = 0, stdout = vim.json.encode({ data = { search = { nodes = {} } } }) })
    end
    vim.cmd("edit github://owner/repo/issues")
    assert.same({ "0 issues" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("advises installation when gh is unavailable without interrupting editing", function()
    local path = vim.env.PATH
    vim.env.PATH = vim.fn.tempname()
    vim.cmd("edit github://owner/repo/issues")
    assert.is_true(vim.wait(2000, function()
      return #notices > 0
    end))
    vim.env.PATH = path
    assert.same({ "GitHub owner/repo: gh is not installed; install GitHub CLI (https://cli.github.com/)" }, notices)
    assert.same({ "Issue search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "still editing" })
    assert.equals("still editing", vim.api.nvim_get_current_line())
  end)
  for _, scenario in ipairs({
    {
      name = "not authenticated",
      result = { code = 4, stdout = "", stderr = "To get started with GitHub CLI, please run: gh auth login" },
      expected = "GitHub owner/repo: gh is not authenticated; run gh auth login --hostname github.com",
    },
    {
      name = "invalid credentials",
      result = { code = 1, stdout = "", stderr = "HTTP 401: Bad credentials (https://api.github.com/graphql)" },
      expected = "GitHub owner/repo: gh is not authenticated; run gh auth login --hostname github.com",
    },
    {
      name = "other access failure",
      result = { code = 1, stdout = "", stderr = "HTTP 403: forbidden" },
      expected = "GitHub owner/repo: GitHub request failed (exit 1)",
    },
  }) do
    it("reports " .. scenario.name .. " while leaving editing usable", function()
      require("github.core.process").run = function(_, _, cb)
        cb(scenario.result)
      end
      vim.cmd("edit github://owner/repo/issues")
      assert.same({ "Issue search failed" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.same({ scenario.expected }, notices)
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "still editing" })
      assert.equals("still editing", vim.api.nvim_get_current_line())
    end)
  end
  it("reports installed and authenticated gh through health checks", function()
    local saved_health, saved_path = vim.health, vim.env.PATH
    local messages = {}
    vim.health = {
      start = function(message)
        messages[#messages + 1] = { "start", message }
      end,
      ok = function(message)
        messages[#messages + 1] = { "ok", message }
      end,
      error = function(message)
        messages[#messages + 1] = { "error", message }
      end,
    }
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "#!/bin/sh", '[ "$*" = "auth status --hostname github.com" ]' }, dir .. "/gh")
    vim.fn.setfperm(dir .. "/gh", "rwx------")
    vim.env.PATH = dir
    require("github.health").check()
    vim.env.PATH, vim.health = saved_path, saved_health
    vim.fn.delete(dir, "rf")
    assert.same(
      { { "start", "github.nvim" }, { "ok", "gh is installed" }, { "ok", "gh is authenticated for github.com" } },
      messages
    )
  end)
  it("reports missing and unauthenticated gh in health checks", function()
    local saved_health, saved_path = vim.health, vim.env.PATH
    local messages = {}
    vim.health = {
      start = function(message)
        messages[#messages + 1] = { "start", message }
      end,
      ok = function(message)
        messages[#messages + 1] = { "ok", message }
      end,
      error = function(message)
        messages[#messages + 1] = { "error", message }
      end,
    }
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.env.PATH = dir
    require("github.health").check()
    vim.fn.writefile({ "#!/bin/sh", "exit 1" }, dir .. "/gh")
    vim.fn.setfperm(dir .. "/gh", "rwx------")
    require("github.health").check()
    vim.env.PATH, vim.health = saved_path, saved_health
    vim.fn.delete(dir, "rf")
    assert.same({
      { "start", "github.nvim" },
      { "error", "gh is not installed; install GitHub CLI (https://cli.github.com/)" },
      { "start", "github.nvim" },
      { "ok", "gh is installed" },
      { "error", "gh authentication could not be confirmed; run gh auth status --hostname github.com" },
    }, messages)
  end)
end)
