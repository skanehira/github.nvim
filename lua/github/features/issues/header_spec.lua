describe("issue header", function()
  local header = require("github.features.issues.header")
  local LEFT_CAP = "\u{E0B6}"
  local RIGHT_CAP = "\u{E0B4}"
  it("formats assignees, labels and project status", function()
    local lines = header.lines({
      assignees = { nodes = { { login = "alice" }, { login = "bob" } } },
      labels = { nodes = { { name = "bug", color = "ff0000" } } },
      projectItems = {
        nodes = {
          {
            project = { title = "Roadmap" },
            fieldValues = { nodes = { { name = "In progress", field = { name = "Status" } } } },
          },
          { project = { title = "Ideas" } },
        },
      },
    })
    assert.same({
      "Assignees   @alice, @bob",
      "Labels      " .. LEFT_CAP .. "bug" .. RIGHT_CAP,
      "Projects    Roadmap  ·  Status: In progress, Ideas",
    }, lines)
  end)
  it("uses a dash for empty metadata", function()
    assert.same({ "Assignees   —", "Labels      —", "Projects    —" }, header.lines({}))
  end)
  it("parses the header and body", function()
    local parsed = header.parse({
      "Title",
      "Assignees   @alice, bob",
      "Labels      " .. LEFT_CAP .. "bug" .. RIGHT_CAP .. ", help wanted",
      "Projects    Roadmap  ·  Status: In progress, Ideas",
      "line 1",
      "line 2",
    })
    assert.same({
      title = "Title",
      assignees = { "alice", "bob" },
      labels = { "bug", "help wanted" },
      projects = {
        { title = "Roadmap", field = "Status", status = "In progress" },
        { title = "Ideas" },
      },
      body = "line 1\nline 2",
    }, parsed)
  end)
  it("reports missing header lines", function()
    local parsed, err = header.parse({ "Title", "Assignees   —", "Labels      —" })
    assert.is_nil(parsed)
    assert.equals("restore the issue header lines", err)
    local parsed2, err2 = header.parse({ "Title", "Assignees   —", "Wrong", "Projects    —", "body" })
    assert.is_nil(parsed2)
    assert.equals("restore the Labels header line", err2)
  end)
  it("highlights label pills and project status", function()
    local spans = header.spans({
      "Title",
      "Assignees   @alice",
      "Labels      " .. LEFT_CAP .. "bug" .. RIGHT_CAP,
      "Projects    Roadmap  ·  Status: In progress",
    }, {
      assignees = { nodes = { { login = "alice" } } },
      labels = { nodes = { { name = "bug", color = "ff0000" } } },
      projectItems = {
        nodes = {
          {
            project = { title = "Roadmap" },
            fieldValues = { nodes = { { name = "In progress", field = { name = "Status" } } } },
          },
        },
      },
    })
    local function span_for(line, start_col)
      for _, span in ipairs(spans) do
        if span[1] == line and span[2] == start_col then
          return span
        end
      end
    end
    assert.equals("gh_issue_user", span_for(1, 12)[4])
    assert.equals("GitHubIssueLabelCap_ff0000", span_for(2, 12)[4])
    assert.equals("GitHubIssueLabel_ff0000", span_for(2, 15)[4])
    assert.equals("GitHubIssueLabelCap_ff0000", span_for(2, 18)[4])
    assert.equals("gh_issue_project", span_for(3, 12)[4])
    assert.equals("gh_issue_meta", span_for(3, 19)[4])
  end)
end)
