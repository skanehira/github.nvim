local uri = require("github.core.uri")

describe("GitHub URI parsing", function()
  it("maps every supported URI and HTTPS URL to the same target", function()
    local cases = {
      { "", "issue_list" },
      { "/new", "issue_create" },
      { "/42", "issue_edit" },
      { "/42/assignees", "issue_assignees" },
      { "/42/labels", "issue_labels" },
      { "/42/comments", "comment_list" },
      { "/42/comments/new", "comment_create" },
      { "/42/comments/123", "comment_edit" },
    }
    for _, case in ipairs(cases) do
      local parsed = uri.parse("github://owner/repo/issues" .. case[1])
      assert.equals(case[2], parsed.kind)
      assert.same(parsed, uri.parse("https://github.com/owner/repo/issues" .. case[1]))
      assert.equals("github://owner/repo/issues" .. case[1], uri.format(parsed))
    end
  end)

  it("rejects missing and invalid identifiers, hosts, and extra paths", function()
    local cases = {
      "github:///repo/issues",
      "github://owner//issues",
      "github://owner/repo/issues/0",
      "github://owner/repo/issues/-1",
      "github://owner/repo/issues/1/comments/0",
      "github://owner/repo/issues/1/unknown",
      "github://owner/repo/issues/1/labels/x",
      "https://example.com/owner/repo/issues",
      "https://github.com/owner/repo/pulls",
    }
    for _, value in ipairs(cases) do
      local parsed, err = uri.parse(value)
      assert.is_nil(parsed)
      assert.equals("unsupported GitHub URI", err)
    end
  end)
end)
