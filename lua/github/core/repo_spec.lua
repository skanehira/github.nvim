describe("repository context", function()
  it("separates operation cwd and git worktree from the github identity", function()
    local repo = require("github.core.repo")
    local calls = {}
    local run = function(argv, opts, cb)
      calls[#calls + 1] = { argv, opts.cwd }
      if #calls == 1 then
        cb({ code = 0, stdout = "/work/tree\n" })
      else
        cb({ code = 0, stdout = "git@github.com:alice/project.git\n" })
      end
    end
    local actual
    repo.resolve("/work/tree/sub", run, function(value)
      actual = value
    end)
    assert.same(
      { host = "github.com", owner = "alice", repo = "project", local_repo = "/work/tree", cwd = "/work/tree/sub" },
      actual
    )
    assert.same({
      { { "git", "rev-parse", "--show-toplevel" }, "/work/tree/sub" },
      { { "git", "remote", "get-url", "origin" }, "/work/tree/sub" },
    }, calls)
  end)
  it("rejects a non-GitHub origin", function()
    local repo = require("github.core.repo")
    local result, err
    local calls = 0
    repo.resolve("/tmp", function(_, _, cb)
      calls = calls + 1
      cb({ code = 0, stdout = calls == 1 and "/tmp\n" or "git@example.org:alice/project.git\n" })
    end, function(value, e)
      result, err = value, e
    end)
    assert.is_nil(result)
    assert.equals("origin is not a github.com repository", err)
  end)
  it("rejects missing or empty explicit repository names", function()
    local repo = require("github.core.repo")
    local value, err = repo.explicit(nil, "repo")
    assert.is_nil(value)
    assert.equals("invalid repository", err)
    value, err = repo.explicit("owner", "")
    assert.is_nil(value)
    assert.equals("invalid repository", err)
  end)
end)
