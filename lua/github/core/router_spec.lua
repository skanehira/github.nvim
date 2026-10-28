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
