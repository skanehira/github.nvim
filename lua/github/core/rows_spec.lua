local function issue(number, title, state)
  return {
    number = number,
    title = title,
    state = state or "OPEN",
    assignees = { nodes = {} },
    labels = { nodes = {} },
    comments = { totalCount = 0 },
  }
end

local function highlighted_text(lines, spans)
  local values = {}
  for _, span in ipairs(spans) do
    values[#values + 1] = { span[1], lines[span[1] + 1]:sub(span[2] + 1, span[3]), span[4] }
  end
  return values
end

describe("compact GitHub rows", function()
  it("aligns Issue columns including multibyte text and highlights the displayed fields", function()
    local first, second = issue(7, "日本語", "CLOSED"), issue(123, "long title")
    first.assignees.nodes = { { login = "alice" }, { login = "bob" }, { login = "carol" } }
    first.labels.nodes = { { name = "修正" }, { name = "docs" }, { name = "test" }, { name = "hidden" } }
    first.comments.totalCount = 123
    local items = { first, second }
    local before = vim.deepcopy(items)
    local lines, spans = require("github.core.rows").issues(items, { [1] = true })
    assert.same({
      "* #7   日本語     CLOSED @alice @bob (修正, docs, test)  123",
      "  #123 long title OPEN               ()                  0",
    }, lines)
    assert.same({
      { 0, "*", "gh_select" },
      { 0, "#7", "gh_issue_number" },
      { 0, "CLOSED", "gh_issue_closed" },
      { 0, "@alice @bob", "gh_issue_user" },
      { 0, "(修正, docs, test)", "gh_issue_labels" },
      { 1, "#123", "gh_issue_number" },
      { 1, "OPEN", "gh_issue_open" },
      { 1, "()", "gh_issue_labels" },
    }, highlighted_text(lines, spans))
    assert.same(before, items)
  end)

  it("truncates long titles at a display width of 100 without cutting UTF-8 or combining characters", function()
    local titles = {
      { input = string.rep("a", 100), display = string.rep("a", 100) },
      { input = string.rep("a", 101), display = string.rep("a", 100) .. "..." },
      { input = string.rep("界", 51), display = string.rep("界", 50) .. "..." },
      { input = string.rep("é", 101), display = string.rep("é", 100) .. "..." },
      { input = string.rep("🙂", 51), display = string.rep("🙂", 50) .. "..." },
    }
    for _, value in ipairs(titles) do
      local lines = require("github.core.rows").issues({ issue(1, value.input) })
      assert.same({ "  #1 " .. value.display .. " OPEN  ()  0" }, lines)
    end
  end)

  it("keeps control characters out of displayed fields and still uses the total comment count", function()
    local value = issue(1, "first\r\nsecond\tend")
    value.assignees.nodes = { { login = "a\tb" } }
    value.labels.nodes = { { name = "x\ny" } }
    value.comments.totalCount = 1234
    local lines = require("github.core.rows").issues({ value })
    assert.same({ "  #1 first second end OPEN @a b (x y)  1234" }, lines)
  end)

  it("aligns comment authors and first lines, preserves source data and highlights selection", function()
    local items = {
      { user = { login = "a" }, body = "日本語\r\nsecond" },
      { user = { login = "longuser" }, body = "hello\tworld\nsecond" },
      { user = vim.NIL, body = "deleted\r\nsecond" },
    }
    local before = vim.deepcopy(items)
    local lines, spans = require("github.core.rows").comments(items, { [2] = true })
    assert.same({ "  @a        日本語", "* @longuser hello world", "  [deleted] deleted" }, lines)
    assert.same({
      { 0, "@a", "gh_issue_comment_user" },
      { 1, "*", "gh_select" },
      { 1, "@longuser", "gh_issue_comment_user" },
    }, highlighted_text(lines, spans))
    assert.same(before, items)
  end)

  it("shows explicit empty lists and no highlights", function()
    local lines, spans = require("github.core.rows").issues({})
    assert.same({ "0 issues" }, lines)
    assert.same({}, spans)
    lines, spans = require("github.core.rows").comments({})
    assert.same({ "0 comments" }, lines)
    assert.same({}, spans)
  end)
end)
