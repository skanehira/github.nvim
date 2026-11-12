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

  it("round trips pull list URI and HTTPS URL", function()
    local parsed = uri.parse("github://owner/repo/pulls")
    assert.same({ kind = "pull_list", host = "github.com", owner = "owner", repo = "repo" }, parsed)
    assert.same(parsed, uri.parse("https://github.com/owner/repo/pulls"))
    assert.equals("github://owner/repo/pulls", uri.format(parsed))
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
      "https://github.com/owner/repo/pulls/1",
      "github://owner/repo/issuespull_list",
      "github://owner/repo/pulls/new",
      "github://-owner/repo/issues",
      "github://own.er/repo/issues",
      "github://owner/re po/issues",
    }
    for _, value in ipairs(cases) do
      local parsed, err = uri.parse(value)
      assert.is_nil(parsed)
      assert.equals("unsupported GitHub URI", err)
    end
  end)
end)

describe("GitHub URIs without owner and repo", function()
  it("maps every owner-less form to its target and leaves other names unparsed", function()
    local cases = {
      { "github://issues", { kind = "issue_list" } },
      { "github://pulls", { kind = "pull_list" } },
      { "github://issues/new", { kind = "issue_create" } },
      { "github://issues/42", { kind = "issue_edit", issue_number = 42 } },
      { "github://issues/42/assignees", { kind = "issue_assignees", issue_number = 42 } },
      { "github://issues/42/labels", { kind = "issue_labels", issue_number = 42 } },
      { "github://issues/42/comments", { kind = "comment_list", issue_number = 42 } },
      { "github://issues/42/comments/new", { kind = "comment_create", issue_number = 42 } },
      { "github://issues/42/comments/123", { kind = "comment_edit", issue_number = 42, comment_id = 123 } },
      { "github://issues/0" },
      { "github://issues/42/unknown" },
      { "github://issues/42/comments/0" },
      { "github://pulls/1" },
      { "github://issuesx" },
      { "github://issues/repo/issues" },
      { "github://owner/repo/issues/42" },
      { "https://github.com/issues/42" },
    }
    for _, case in ipairs(cases) do
      assert.same(case[2], uri.parse_current_repository(case[1]))
    end
  end)
end)
