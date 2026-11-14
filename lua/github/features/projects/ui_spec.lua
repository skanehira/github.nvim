local float = require("github.core.float")
local ui = require("github.features.projects.ui")

local function key(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
end

local function float_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function close_all()
  for _, win in ipairs(float_windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.cmd("silent! only!")
  vim.cmd("silent! tabonly")
end

local function spanned(lines, spans)
  local values = {}
  for _, span in ipairs(spans) do
    values[#values + 1] = { span[1], lines[span[1] + 1]:sub(span[2] + 1, span[3]), span[4] }
  end
  return values
end

local function contents(lines)
  local values = {}
  for _, line in ipairs(lines) do
    values[#values + 1] = line:gsub(" +$", "")
  end
  return values
end

local function mapping(buf, mode, lhs)
  for _, value in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if value.lhs == lhs then
      return value
    end
  end
end

local function assert_mapping(buf, mode, lhs)
  local value = mapping(buf, mode, lhs)
  assert.is_not_nil(value)
  assert.equals(1, value.silent)
  assert.equals(1, value.nowait)
end

local function highlights(buf)
  local values = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
  do
    local row, col, detail = mark[2], mark[3], mark[4]
    values[#values + 1] = { row, vim.api.nvim_buf_get_text(buf, row, col, row, detail.end_col, {})[1], detail.hl_group }
  end
  return values
end

local function full_issue()
  return {
    id = "item-1",
    type = "ISSUE",
    values = {},
    archived = false,
    content = {
      number = 7,
      title = "日本語のタイトル",
      state = "OPEN",
      url = "https://github.com/a/r/issues/7",
      repository = { nameWithOwner = "a/r" },
      labels = { totalCount = 3, nodes = { { name = "bug" }, { name = "修正" } } },
      assignees = { totalCount = 2, nodes = { { login = "alice" }, { login = "bob" } } },
      subIssuesSummary = { total = 4, completed = 1 },
      closedByPullRequestsReferences = { totalCount = 3, nodes = { { number = 12 }, { number = 13 } } },
    },
  }
end

describe("projects ui", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    require("github.core.highlight").setup()
  end)
  after_each(function()
    close_all()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  describe("text helpers", function()
    it("truncates text by display width and appends an ellipsis", function()
      assert.equals("short", ui.truncate("short", 10))
      assert.equals(string.rep("a", 100), ui.truncate(string.rep("a", 100), 100))
      assert.equals(string.rep("a", 97) .. "...", ui.truncate(string.rep("a", 101), 100))
      assert.equals("日本...", ui.truncate("日本語のタイトル", 8))
      assert.equals(string.rep("🙂", 48) .. "...", ui.truncate(string.rep("🙂", 51), 100))
      assert.equals("日", ui.truncate("日本語", 2))
      assert.equals("", ui.truncate("日本語", 1))
      assert.equals("...", ui.truncate("abcdef", 3))
      assert.equals("a  b c", ui.truncate("a\r\nb\tc", 10))
      assert.equals("", ui.truncate("abc", 0))
    end)

    it("pads text to a display width without exceeding it", function()
      assert.equals("abc  ", ui.pad("abc", 5))
      assert.equals("日本語  ", ui.pad("日本語", 8))
      assert.equals("a...", ui.pad("abcdef", 4))
      assert.equals("... ", ui.pad("日本語", 4))
      assert.equals("     ", ui.pad("", 5))
      assert.equals(8, vim.fn.strdisplaywidth(ui.pad("日本語", 8)))
    end)

    it("computes the column width and the number of visible columns", function()
      assert.equals(36, ui.column_width(78))
      assert.equals(20, ui.column_width(78, 10))
      assert.equals(80, ui.column_width(100, 90))
      assert.equals(18, ui.column_width(18, 36))
      assert.equals(1, ui.column_width(0, 36))

      assert.equals(2, ui.visible_columns(78, 36))
      assert.equals(2, ui.visible_columns(80, 36))
      assert.equals(3, ui.visible_columns(120, 36))
      assert.equals(3, ui.visible_columns(78, 20))
      assert.equals(1, ui.visible_columns(1, 1))

      assert.equals(37, ui.board_column_width(230, 36, 6))
      assert.equals(114, ui.board_column_width(230, 80, 2))
      assert.equals(50, ui.board_column_width(50, 36, 1))
      assert.equals(49, ui.board_column_width(100, 36, 2))
      assert.equals(30, ui.board_column_width(30, 36, 1))
      assert.equals(1, ui.board_column_width(0, 36, 1))

      assert.same({ 37, 37, 37, 37, 37, 40 }, ui.board_column_widths(230, 36, 6))
      assert.same({ 114, 115 }, ui.board_column_widths(230, 80, 2))
      assert.same({ 50 }, ui.board_column_widths(50, 36, 1))
      assert.same({ 49, 50 }, ui.board_column_widths(100, 36, 2))
      assert.same({ 30 }, ui.board_column_widths(30, 36, 1))
      assert.same({ 1 }, ui.board_column_widths(0, 36, 1))
    end)

    it("keeps the selected column inside the visible range", function()
      assert.equals(1, ui.first_col(1, 3, 1, 10))
      assert.equals(2, ui.first_col(1, 3, 4, 10))
      assert.equals(8, ui.first_col(1, 3, 10, 10))
      assert.equals(2, ui.first_col(5, 3, 2, 10))
      assert.equals(1, ui.first_col(5, 3, 1, 2))
      assert.equals(2, ui.first_col(1, 1, 2, 10))
    end)

    it("joins header parts and shows loading, failure and truncation states", function()
      assert.equals("a  ·  b", ui.join({ "a", "b" }))
      assert.equals("a  ·  b", ui.join({ "a", nil, "", "b" }))
      assert.equals("", ui.join({}))

      local text, spans = ui.header({ text = "Projects for alice (user)  ·  3 open" })
      assert.equals("Projects for alice (user)  ·  3 open", text)
      assert.same({ { 0, text, "GitHubProjectsHeader" } }, spanned({ text }, spans))

      text, spans = ui.header({ loading = "Loading projects..." })
      assert.equals("Loading projects...", text)
      assert.same({ { 0, text, "GitHubProjectsLoading" } }, spanned({ text }, spans))

      text, spans = ui.header({ text = "board", error = "permission denied" })
      assert.equals("Error: permission denied", text)
      assert.same({ { 0, text, "GitHubProjectsError" } }, spanned({ text }, spans))

      text, spans = ui.header({ text = "board", truncated = "Showing 100 projects" })
      assert.equals("Showing 100 projects", text)
      assert.same({ { 0, text, "GitHubProjectsHeader" } }, spanned({ text }, spans))

      text = ui.header({ text = "board", loading = "Loading 1/2...", error = "boom" })
      assert.equals("Error: boom", text)

      text, spans = ui.header({})
      assert.equals("", text)
      assert.same({}, spans)
    end)
  end)

  describe("cards", function()
    it("renders an Issue card with border, title, labels, avatars, progress and related PRs", function()
      local item = full_issue()
      local before = vim.deepcopy(item)
      local card, spans = ui.card(item, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ◉ #7 日本語のタイトル            │",
        "│                                  │",
        "│  bug  修正  +1                   │",
        "│                              Ⓐ Ⓑ │",
        "│ 1/4 ██████░░░░░░░░░░░░░░░░░░ 25% │",
        "│ ⇄ #12 ⇄ #13 +1                   │",
        "╰──────────────────────────────────╯",
      }, contents(card))
      for _, line in ipairs(card) do
        assert.equals(36, vim.fn.strdisplaywidth(line))
      end
      local groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      for _, name in ipairs({
        "GitHubProjectsCard",
        "GitHubProjectsCardBorder",
        "GitHubProjectsColorGreen",
        "GitHubProjectsNumber",
        "GitHubProjectsCardTitle",
        "GitHubProjectsLabel",
        "GitHubProjectsLabelMore",
        "GitHubProjectsAvatar_alice",
        "GitHubProjectsAvatar_bob",
        "GitHubProjectsProgress",
        "GitHubProjectsProgressEmpty",
        "GitHubProjectsMeta",
      }) do
        assert.is_true(groups[name], name)
      end
      assert.same(before, item)
    end)

    it("wraps a long Japanese title without truncating it and grows the card", function()
      local item = full_issue()
      item.content.title = string.rep("日本語の長いタイトル", 6)
      local card, spans = ui.card(item, 20)
      for _, line in ipairs(card) do
        assert.equals(20, vim.fn.strdisplaywidth(line))
        assert.is_nil(line:find("...", 1, true))
      end
      assert.is_true(#card > 5)
      local title_text = ""
      for _, line in ipairs(card) do
        local content = line:match("^│ (.-) │$") or ""
        content = content:gsub("^%s+", ""):gsub("%s+$", "")
        title_text = title_text .. content
      end
      title_text = title_text:gsub("^◉ #%d+ ", "")
      assert.is_not_nil(title_text:find(string.rep("日本語の長いタイトル", 6), 1, true))
      assert.is_true(#spans > 0)
    end)

    it("wraps Japanese titles at narrow widths without ellipses", function()
      local card = ui.card(full_issue(), 20)
      assert.same({
        "╭──────────────────╮",
        "│ ◉ #7 日本語のタ  │",
        "│      イトル      │",
        "│                  │",
        "│  bug  修正  +1   │",
        "│              Ⓐ Ⓑ │",
        "│ 1/4 ██░░░░░░ 25% │",
        "│ ⇄ #12 ⇄ #13 +1   │",
        "╰──────────────────╯",
      }, contents(card))
      for _, line in ipairs(card) do
        assert.equals(20, vim.fn.strdisplaywidth(line))
        assert.is_nil(line:find("...", 1, true))
      end
    end)

    it("renders PullRequest, DraftIssue and redacted cards with borders", function()
      local pull = {
        type = "PULL_REQUEST",
        values = {},
        content = {
          number = 42,
          title = "Fix crash",
          state = "OPEN",
          labels = { totalCount = 1, nodes = { { name = "bug" } } },
          assignees = { totalCount = 0, nodes = {} },
        },
      }
      local card, spans = ui.card(pull, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ⇄ #42 Fix crash                  │",
        "│                                  │",
        "│  bug                             │",
        "╰──────────────────────────────────╯",
      }, contents(card))
      local groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_true(groups.GitHubProjectsColorGreen)
      assert.is_true(groups.GitHubProjectsNumber)
      assert.is_true(groups.GitHubProjectsCardTitle)
      assert.is_true(groups.GitHubProjectsLabel)

      card, spans = ui.card({ type = "DRAFT_ISSUE", values = {}, content = { title = "下書き", body = "body" } }, 20)
      assert.same({
        "╭──────────────────╮",
        "│ ✎ 下書き         │",
        "╰──────────────────╯",
      }, contents(card))
      groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_true(groups.GitHubProjectsColorGray)
      assert.is_true(groups.GitHubProjectsNumber)
      assert.is_true(groups.GitHubProjectsCardTitle)

      card, spans = ui.card({ type = "REDACTED", values = {}, content = nil }, 20)
      assert.same({
        "╭──────────────────╮",
        "│ [redacted]       │",
        "╰──────────────────╯",
      }, contents(card))
      groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_true(groups.GitHubProjectsRedacted)

      card, spans = ui.card({ type = "ISSUE", values = {}, content = nil }, 20)
      assert.same({
        "╭──────────────────╮",
        "│ [redacted]       │",
        "╰──────────────────╯",
      }, contents(card))
      groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_true(groups.GitHubProjectsRedacted)
    end)

    it("omits the meta, progress and related PR lines when there is nothing to show", function()
      local item = {
        type = "ISSUE",
        values = {},
        content = {
          number = 1,
          title = "Only title",
          state = "OPEN",
          labels = { totalCount = 0, nodes = {} },
          assignees = { totalCount = 0, nodes = {} },
          subIssuesSummary = { total = 0, completed = 0 },
          closedByPullRequestsReferences = { totalCount = 0, nodes = {} },
        },
      }
      local card, spans = ui.card(item, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ◉ #1 Only title                  │",
        "╰──────────────────────────────────╯",
      }, contents(card))
      local groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_nil(groups.GitHubProjectsLabel)
      assert.is_nil(groups.GitHubProjectsAvatar_alice)
      assert.is_nil(groups.GitHubProjectsProgress)

      card = ui.card({
        type = "PULL_REQUEST",
        values = {},
        content = {
          number = 2,
          title = "Only title",
          state = "OPEN",
          labels = { totalCount = 0, nodes = {} },
          assignees = { totalCount = 0, nodes = {} },
        },
      }, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ⇄ #2 Only title                  │",
        "╰──────────────────────────────────╯",
      }, contents(card))
    end)

    it("highlights every line of a selected card with background and border spans", function()
      local card, spans = ui.card(full_issue(), 36, true)
      local background, border = {}, {}
      for _, span in ipairs(spans) do
        if span[4] == "GitHubProjectsCardSelected" then
          assert.equals(3, span[2])
          assert.equals(#card[span[1] + 1] - 3, span[3])
          background[span[1]] = true
        elseif span[4] == "GitHubProjectsCardSelectedBorder" then
          border[span[1]] = true
        end
      end
      for index = 0, #card - 1 do
        assert.is_true(border[index], "missing selected border on line " .. index)
      end
      for index = 1, #card - 2 do
        assert.is_true(background[index], "missing selected background on line " .. index)
      end
      assert.is_nil(background[0], "unexpected background on the top border")
      assert.is_nil(background[#card - 1], "unexpected background on the bottom border")
    end)

    it("draws the selected border above the background on every side", function()
      local card, spans = ui.card(full_issue(), 36, true)
      local top_bottom, left, right = false, false, false
      for _, span in ipairs(spans) do
        if span[4] == "GitHubProjectsCardSelectedBorder" then
          assert.equals(10, span[5])
          local line = card[span[1] + 1]
          if span[2] == 0 and span[3] == #line then
            top_bottom = true
          elseif span[2] == 0 and span[3] == 3 then
            left = true
          elseif span[2] == #line - 3 and span[3] == #line then
            right = true
          end
        end
      end
      assert.is_true(top_bottom, "missing top/bottom border")
      assert.is_true(left, "missing left border")
      assert.is_true(right, "missing right border")
    end)

    it("uses the same border group on every side of an unselected card", function()
      local card, spans = ui.card(full_issue(), 36, false)
      local left, right = false, false
      for _, span in ipairs(spans) do
        if span[4] == "GitHubProjectsCardBorder" then
          assert.equals(10, span[5])
          local line = card[span[1] + 1]
          if span[2] == 0 and span[3] == 3 then
            left = true
          elseif span[2] == #line - 3 and span[3] == #line then
            right = true
          end
        end
      end
      assert.is_true(left, "missing left border")
      assert.is_true(right, "missing right border")
    end)

    it("uses a double-line border for a selected card", function()
      local card = ui.card(full_issue(), 36, true)
      assert.equals("╔" .. string.rep("═", 34) .. "╗", card[1])
      assert.equals("╚" .. string.rep("═", 34) .. "╝", card[#card])
      assert.equals("║", card[2]:sub(1, 3))
      assert.equals("║", card[2]:sub(-3))
    end)

    it("shows the remaining label and assignee counts as +N", function()
      local item = {
        type = "ISSUE",
        values = {},
        content = {
          number = 1,
          title = "T",
          state = "OPEN",
          labels = { totalCount = 5, nodes = { { name = "a" }, { name = "b" } } },
          assignees = { totalCount = 4, nodes = { { login = "x" }, { login = "y" } } },
          subIssuesSummary = { total = 0, completed = 0 },
          closedByPullRequestsReferences = { totalCount = 0, nodes = {} },
        },
      }
      local card, spans = ui.card(item, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ◉ #1 T                           │",
        "│                                  │",
        "│  a  b  +3                        │",
        "│                           Ⓧ Ⓨ +2 │",
        "╰──────────────────────────────────╯",
      }, contents(card))
      local groups = {}
      for _, span in ipairs(spans) do
        groups[span[4]] = true
      end
      assert.is_true(groups.GitHubProjectsLabelMore)
      assert.is_true(groups.GitHubProjectsMeta)
    end)

    it("keeps control characters out of card text", function()
      local item = {
        type = "ISSUE",
        values = {},
        content = {
          number = 1,
          title = "a\r\nb\tc",
          state = "OPEN",
          labels = { totalCount = 1, nodes = { { name = "x\ny" } } },
          assignees = { totalCount = 1, nodes = { { login = "a\tb" } } },
          subIssuesSummary = { total = 0, completed = 0 },
          closedByPullRequestsReferences = { totalCount = 0, nodes = {} },
        },
      }
      local card = ui.card(item, 36)
      assert.same({
        "╭──────────────────────────────────╮",
        "│ ◉ #1 a  b c                      │",
        "│                                  │",
        "│  x y                             │",
        "│                                Ⓐ │",
        "╰──────────────────────────────────╯",
      }, contents(card))
      for _, line in ipairs(card) do
        assert.is_nil(line:find("\r", 1, true))
        assert.is_nil(line:find("\t", 1, true))
        assert.is_nil(line:find("\n", 1, true))
      end
    end)
  end)

  describe("column headers", function()
    it("renders column headers with the option color, count and add button", function()
      local text, spans = ui.column_header({ name = "Todo", count = 3, color = "BLUE" }, 36)
      assert.equals("● Todo 3" .. string.rep(" ", 26) .. " +", text)
      assert.same({
        { 0, text, "GitHubProjectsColumnHeader" },
        { 0, "●", "GitHubProjectsColorBlue" },
        { 0, "Todo", "GitHubProjectsColumn" },
        { 0, "3", "GitHubProjectsMeta" },
        { 0, "+", "GitHubProjectsMeta" },
      }, spanned({ text }, spans))

      text, spans = ui.column_header({ name = "Todo", count = 3, color = "BLUE" }, 36, true)
      assert.equals("● Todo 3" .. string.rep(" ", 26) .. " +", text)
      assert.same({
        { 0, text, "GitHubProjectsColumnSelected" },
        { 0, "●", "GitHubProjectsColorBlue" },
        { 0, "Todo", "GitHubProjectsColumn" },
        { 0, "3", "GitHubProjectsColumnSelected" },
        { 0, "+", "GitHubProjectsColumnSelected" },
      }, spanned({ text }, spans))

      text, spans = ui.column_header({ no_value = true, count = 2 }, 36)
      assert.equals("○ 値なし 2" .. string.rep(" ", 24) .. " +", text)
      assert.same({
        { 0, text, "GitHubProjectsColumnHeader" },
        { 0, "値なし", "GitHubProjectsColumn" },
        { 0, "2", "GitHubProjectsMeta" },
        { 0, "+", "GitHubProjectsMeta" },
      }, spanned({ text }, spans))

      text, spans = ui.column_header({ name = "進行中", count = 5, color = "GREEN" }, 8)
      assert.equals("● ...  +", text)
      assert.same({
        { 0, text, "GitHubProjectsColumnHeader" },
        { 0, "●", "GitHubProjectsColorGreen" },
        { 0, "...", "GitHubProjectsColumn" },
        { 0, "+", "GitHubProjectsMeta" },
      }, spanned({ text }, spans))
    end)
  end)

  describe("highlights", function()
    it("maps API colors to project highlight groups", function()
      local expected = {
        GRAY = "GitHubProjectsColorGray",
        RED = "GitHubProjectsColorRed",
        ORANGE = "GitHubProjectsColorOrange",
        YELLOW = "GitHubProjectsColorYellow",
        GREEN = "GitHubProjectsColorGreen",
        PINK = "GitHubProjectsColorPink",
        PURPLE = "GitHubProjectsColorPurple",
        BLUE = "GitHubProjectsColorBlue",
      }
      for color, group in pairs(expected) do
        assert.equals(group, ui.color_group(color))
      end
      assert.equals("GitHubProjectsColorBlue", ui.color_group("blue"))
      assert.is_nil(ui.color_group("WHITE"))
      assert.is_nil(ui.color_group(nil))
    end)

    it("defines the project highlight groups with GitHub-like defaults", function()
      local groups = {
        "GitHubProjectsToolbar",
        "GitHubProjectsHeader",
        "GitHubProjectsColumnHeader",
        "GitHubProjectsColumnBg",
        "GitHubProjectsColumn",
        "GitHubProjectsColumnSelected",
        "GitHubProjectsCard",
        "GitHubProjectsCardBorder",
        "GitHubProjectsCardSelected",
        "GitHubProjectsCardSelectedBorder",
        "GitHubProjectsCardTitle",
        "GitHubProjectsNumber",
        "GitHubProjectsMeta",
        "GitHubProjectsProgress",
        "GitHubProjectsProgressEmpty",
        "GitHubProjectsLabel",
        "GitHubProjectsLabelMore",
        "GitHubProjectsAvatar",
        "GitHubProjectsEmpty",
        "GitHubProjectsRedacted",
        "GitHubProjectsError",
        "GitHubProjectsLoading",
        "GitHubProjectsColorGray",
        "GitHubProjectsColorRed",
        "GitHubProjectsColorOrange",
        "GitHubProjectsColorYellow",
        "GitHubProjectsColorGreen",
        "GitHubProjectsColorPink",
        "GitHubProjectsColorPurple",
        "GitHubProjectsColorBlue",
      }
      for _, name in ipairs(groups) do
        assert.equals(1, vim.fn.hlexists(name), name)
      end
      assert.equals("Comment", vim.api.nvim_get_hl(0, { name = "GitHubProjectsRedacted", link = true }).link)
      assert.equals("DiagnosticError", vim.api.nvim_get_hl(0, { name = "GitHubProjectsError", link = true }).link)
      assert.equals("DiagnosticWarn", vim.api.nvim_get_hl(0, { name = "GitHubProjectsLoading", link = true }).link)
      assert.equals(0x161b22, vim.api.nvim_get_hl(0, { name = "GitHubProjectsToolbar" }).bg)
      assert.equals(0x1f6feb, vim.api.nvim_get_hl(0, { name = "GitHubProjectsColumnSelected" }).bg)
      assert.equals(0x0d1117, vim.api.nvim_get_hl(0, { name = "GitHubProjectsCard" }).bg)
      assert.equals(0xe6edf3, vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardBorder" }).fg)
      assert.equals(0x0d1117, vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardBorder" }).bg)
      assert.equals(0xf1c40f, vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardSelectedBorder" }).fg)
      assert.equals(0x161b22, vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardSelectedBorder" }).bg)
      assert.is_true(vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardSelectedBorder" }).bold)
      assert.is_true(vim.api.nvim_get_hl(0, { name = "GitHubProjectsCardTitle" }).bold)
      assert.equals(0x3fb950, vim.api.nvim_get_hl(0, { name = "GitHubProjectsColorGreen" }).fg)
      assert.equals(0x58a6ff, vim.api.nvim_get_hl(0, { name = "GitHubProjectsColorBlue" }).fg)
    end)
  end)

  describe("span application", function()
    it("applies extmark spans and clears stale highlights", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "○ #7", "日本語" })
      ui.apply(buf, {
        { 0, 0, 6, "GitHubProjectsNumber" },
        { 1, 0, 9, "GitHubProjectsMeta" },
      })
      assert.same({
        { 0, "○ #7", "GitHubProjectsNumber" },
        { 1, "日本語", "GitHubProjectsMeta" },
      }, highlights(buf))
      ui.apply(buf, {})
      assert.same({}, highlights(buf))
    end)

    it("passes the span priority to the extmark", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "│ card │" })
      ui.apply(buf, {
        { 0, 0, 8, "GitHubProjectsCard" },
        { 0, 0, 8, "GitHubProjectsCardBorder", 10 },
      })
      local priorities = {}
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().github, 0, -1, { details = true }))
      do
        priorities[mark[4].hl_group] = mark[4].priority
      end
      assert.equals(0, priorities.GitHubProjectsCard)
      assert.equals(10, priorities.GitHubProjectsCardBorder)
    end)
  end)

  describe("keymaps", function()
    it("registers buffer-local mappings with silent and nowait", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local invoked = {}
      local keys = {
        "j",
        "k",
        "<CR>",
        "r",
        "q",
        "<Esc>",
        "h",
        "l",
        "H",
        "L",
        "g",
        "G",
        "K",
        "<C-O>",
        "ghy",
        "ghs",
        "ghe",
        "ghn",
        "ghd",
        "?",
      }
      local maps = {}
      for _, lhs in ipairs(keys) do
        maps[lhs] = function()
          invoked[#invoked + 1] = lhs
        end
      end
      ui.keymaps(buf, { n = maps })
      for _, lhs in ipairs(keys) do
        assert_mapping(buf, "n", lhs)
      end
      vim.api.nvim_set_current_buf(buf)
      key("j")
      assert.same({ "j" }, invoked)
    end)
  end)

  describe("input screen", function()
    it("opens a one-line input and submits with the normal-mode mapping", function()
      local parent = vim.api.nvim_get_current_win()
      local submitted, cancelled = {}, {}
      local handle = ui.open_input({
        name = "projects-input:filter",
        parent = parent,
        prompt = "Filter",
        value = "state:open",
        on_submit = function(value, close)
          submitted[#submitted + 1] = value
          close()
        end,
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      assert.equals(handle.win, vim.api.nvim_get_current_win())
      assert.same({ "state:open" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.equals("gh-projects-input", vim.bo[handle.buf].filetype)
      assert.is_true(vim.bo[handle.buf].modifiable)
      assert.is_false(vim.bo[handle.buf].readonly)
      assert.same({ { "Filter", "FloatTitle" } }, vim.api.nvim_win_get_config(handle.win).title)
      assert.same({ 1, 10 }, vim.api.nvim_win_get_cursor(handle.win))
      assert_mapping(handle.buf, "n", "<CR>")
      assert_mapping(handle.buf, "n", "<C-C>")
      assert_mapping(handle.buf, "n", "q")
      assert_mapping(handle.buf, "i", "<CR>")
      assert_mapping(handle.buf, "i", "<C-C>")

      key("<CR>")
      assert.same({ "state:open" }, submitted)
      assert.is_false(float.is_open("projects-input:filter"))
      assert.equals(parent, vim.api.nvim_get_current_win())
      assert.same({}, cancelled)
    end)

    it("keeps the input open when submit does not close it and cancels on q or CTRL-C", function()
      local parent = vim.api.nvim_get_current_win()
      local submitted, cancelled = {}, {}
      local handle = ui.open_input({
        name = "projects-input:title",
        parent = parent,
        prompt = "Draft title",
        value = "",
        on_submit = function(value)
          submitted[#submitted + 1] = value
        end,
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, { "  " })
      key("<CR>")
      assert.same({ "  " }, submitted)
      assert.is_true(float.is_open("projects-input:title"))
      key("q")
      assert.same({ true }, cancelled)
      assert.is_false(float.is_open("projects-input:title"))
      assert.equals(parent, vim.api.nvim_get_current_win())

      ui.open_input({
        name = "projects-input:existing",
        parent = parent,
        value = "a/r#1",
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      key("<C-C>")
      assert.is_false(float.is_open("projects-input:existing"))
      assert.same({ true, true }, cancelled)
    end)

    it("reuses an input screen and refreshes its value and cursor", function()
      local parent = vim.api.nvim_get_current_win()
      local first = ui.open_input({ name = "projects-input:reuse", parent = parent, value = "one" })
      local second = ui.open_input({ name = "projects-input:reuse", parent = parent, value = "two" })
      assert.equals(first.win, second.win)
      assert.same({ "two" }, vim.api.nvim_buf_get_lines(second.buf, 0, -1, false))
      assert.same({ 1, 3 }, vim.api.nvim_win_get_cursor(second.win))
    end)
  end)

  describe("confirm screen", function()
    it("opens a confirmation and handles y, n, q and Escape", function()
      local parent = vim.api.nvim_get_current_win()
      local confirmed, cancelled = {}, {}
      local confirm_lines = { "Delete this item from the project?", "○ #7 Title", "y: delete  n/q/Esc: cancel" }
      local handle = ui.open_confirm({
        name = "projects-confirm:delete",
        parent = parent,
        lines = confirm_lines,
        on_confirm = function(close)
          confirmed[#confirmed + 1] = type(close)
          close()
        end,
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      assert.same(confirm_lines, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.is_false(vim.bo[handle.buf].modifiable)
      assert.is_true(vim.bo[handle.buf].readonly)
      assert.equals(3, vim.api.nvim_win_get_config(handle.win).height)
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      assert_mapping(handle.buf, "n", "y")
      assert_mapping(handle.buf, "n", "n")
      assert_mapping(handle.buf, "n", "q")
      assert_mapping(handle.buf, "n", "<Esc>")

      key("y")
      assert.same({ "function" }, confirmed)
      assert.is_false(float.is_open("projects-confirm:delete"))
      assert.equals(parent, vim.api.nvim_get_current_win())

      for _, press in ipairs({ "n", "q", "<Esc>" }) do
        ui.open_confirm({
          name = "projects-confirm:delete",
          parent = parent,
          lines = confirm_lines,
          on_cancel = function()
            cancelled[#cancelled + 1] = true
          end,
        })
        assert.is_true(float.is_open("projects-confirm:delete"))
        key(press)
        assert.is_false(float.is_open("projects-confirm:delete"))
      end
      assert.equals(3, #cancelled)
    end)

    it("keeps the confirmation open when the confirm callback does not close it", function()
      local parent = vim.api.nvim_get_current_win()
      ui.open_confirm({
        name = "projects-confirm:keep",
        parent = parent,
        lines = { "Delete?", "○ #1", "y: delete  n/q/Esc: cancel" },
        on_confirm = function() end,
      })
      key("y")
      assert.is_true(float.is_open("projects-confirm:keep"))
    end)
  end)

  describe("preview screen", function()
    it("opens a preview with a header and body and scrolls with the mappings", function()
      local parent = vim.api.nvim_get_current_win()
      local handle = ui.open_preview({
        name = "projects-preview:body",
        parent = parent,
        header = "Issue #7 Title",
        body = "first\r\nsecond\nthird",
      })
      assert.same(
        { "Issue #7 Title", "first", "second", "third" },
        vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
      )
      assert.equals("gh-projects-preview", vim.bo[handle.buf].filetype)
      assert.equals("markdown", vim.bo[handle.buf].syntax)
      assert.is_false(vim.bo[handle.buf].modifiable)
      assert.same({ { 0, "Issue #7 Title", "GitHubProjectsHeader" } }, highlights(handle.buf))
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      for _, lhs in ipairs({ "j", "k", "gg", "G", "<C-D>", "<C-U>", "q", "<Esc>" }) do
        assert_mapping(handle.buf, "n", lhs)
      end

      key("j")
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("j")
      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("G")
      assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("gg")
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("<C-D>")
      assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("<C-U>")
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("q")
      assert.is_false(float.is_open("projects-preview:body"))
      assert.equals(parent, vim.api.nvim_get_current_win())
    end)

    it("shows loading and failure states in the preview header", function()
      local parent = vim.api.nvim_get_current_win()
      local handle = ui.open_preview({
        name = "projects-preview:loading",
        parent = parent,
        header = "Issue #7",
        loading = "Loading body...",
      })
      assert.same({ "Loading body..." }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.same({ { 0, "Loading body...", "GitHubProjectsLoading" } }, highlights(handle.buf))

      handle = ui.open_preview({
        name = "projects-preview:error",
        parent = parent,
        header = "Issue #7",
        error = "not found",
      })
      assert.same({ "Error: not found" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.same({ { 0, "Error: not found", "GitHubProjectsError" } }, highlights(handle.buf))

      handle = ui.open_preview({ name = "projects-preview:empty", parent = parent, header = "Issue #8", body = "" })
      assert.same({ "Issue #8" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
    end)

    it("updates a preview in place and discards a closed or moved screen", function()
      local parent = vim.api.nvim_get_current_win()
      local handle = ui.open_preview({
        name = "projects-preview:update",
        parent = parent,
        header = "Issue #7",
        loading = "Loading body...",
      })

      assert.is_true(ui.update_preview(handle, { header = "Issue #7 Title", body = "first\nsecond" }))
      assert.same({ "Issue #7 Title", "first", "second" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.equals(handle.win, vim.api.nvim_get_current_win())

      vim.cmd("tabnew")
      local other = vim.api.nvim_get_current_win()
      local other_tab = vim.api.nvim_get_current_tabpage()
      assert.is_true(ui.update_preview(handle, { header = "Issue #7 Title", body = "body from another tab" }))
      assert.same({ "Issue #7 Title", "body from another tab" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.equals(other, vim.api.nvim_get_current_win())

      assert.is_false(
        ui.update_preview({ win = handle.win, buf = handle.buf, tab = other_tab }, { header = "Issue #7 Title" })
      )

      vim.cmd("tabnext 1")
      handle.close()
      assert.is_false(ui.update_preview(handle, { header = "Issue #7 Title", body = "late body" }))
    end)
  end)

  describe("help screen", function()
    it("renders an aligned key table and scrolls with the mappings", function()
      local parent = vim.api.nvim_get_current_win()
      local handle = ui.open_help({
        name = "projects-help:board",
        parent = parent,
        rows = { { "j", "次の項目" }, { "gg", "先頭" }, { "G", "末尾" }, { "q", "閉じる" } },
      })
      assert.same({
        "j   次の項目",
        "gg  先頭",
        "G   末尾",
        "q   閉じる",
      }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.equals("gh-projects-help", vim.bo[handle.buf].filetype)
      assert.is_false(vim.bo[handle.buf].modifiable)
      for _, lhs in ipairs({ "j", "k", "gg", "G", "q", "<Esc>" }) do
        assert_mapping(handle.buf, "n", lhs)
      end

      key("G")
      assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("gg")
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("j")
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("q")
      assert.is_false(float.is_open("projects-help:board"))
      assert.equals(parent, vim.api.nvim_get_current_win())
    end)
  end)

  describe("select screen", function()
    it("opens a select screen and moves the selection with the mappings", function()
      local parent = vim.api.nvim_get_current_win()
      local selected, cancelled = {}, {}
      local handle = ui.open_select({
        name = "projects-select:status",
        parent = parent,
        rows = { "● Todo", "● Doing", "値を解除" },
        selected = 2,
        on_select = function(index, close)
          selected[#selected + 1] = index
          close()
        end,
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      assert.same({ "● Todo", "● Doing", "値を解除" }, vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false))
      assert.is_false(vim.bo[handle.buf].modifiable)
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      assert.same({ { 1, "● Doing", "GitHubProjectsCardSelected" } }, highlights(handle.buf))
      for _, lhs in ipairs({ "j", "k", "<CR>", "q", "<Esc>" }) do
        assert_mapping(handle.buf, "n", lhs)
      end

      key("j")
      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      assert.same({ { 2, "値を解除", "GitHubProjectsCardSelected" } }, highlights(handle.buf))
      key("k")
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      key("<CR>")
      assert.same({ 2 }, selected)
      assert.is_false(float.is_open("projects-select:status"))
      assert.equals(parent, vim.api.nvim_get_current_win())

      local choice = ui.open_select({
        name = "projects-select:choice",
        parent = parent,
        rows = { "既存のIssue/PR", "下書きIssue" },
        height = 4,
        on_cancel = function()
          cancelled[#cancelled + 1] = true
        end,
      })
      assert.equals(4, vim.api.nvim_win_get_config(choice.win).height)
      assert.equals(47, vim.api.nvim_win_get_config(choice.win).width)
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(choice.win))
      assert.same({ { 0, "既存のIssue/PR", "GitHubProjectsCardSelected" } }, highlights(choice.buf))
      key("q")
      assert.is_false(float.is_open("projects-select:choice"))
      assert.same({ true }, cancelled)
    end)

    it("clamps the selection and tolerates an empty row list", function()
      local parent = vim.api.nvim_get_current_win()
      local handle = ui.open_select({
        name = "projects-select:clamp",
        parent = parent,
        rows = { "a", "b", "c" },
        selected = 9,
      })
      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(handle.win))
      assert.same({ { 2, "c", "GitHubProjectsCardSelected" } }, highlights(handle.buf))

      local empty = ui.open_select({ name = "projects-select:empty", parent = parent, rows = {} })
      assert.same({ "" }, vim.api.nvim_buf_get_lines(empty.buf, 0, -1, false))
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(empty.win))
      assert.same({}, highlights(empty.buf))
      key("<CR>")
      assert.is_true(float.is_open("projects-select:empty"))
    end)
  end)

  describe("resize", function()
    it("recomputes widths and proportional heights for every screen after VimResized", function()
      local parent = vim.api.nvim_get_current_win()
      local handles = {
        input = ui.open_input({ name = "resize-input", parent = parent }),
        confirm = ui.open_confirm({ name = "resize-confirm", parent = parent, lines = { "a", "b", "c" } }),
        preview = ui.open_preview({ name = "resize-preview", parent = parent, header = "h", body = "b" }),
        help = ui.open_help({ name = "resize-help", parent = parent, rows = { { "j", "次" } } }),
        select = ui.open_select({ name = "resize-select", parent = parent, rows = { "a" } }),
        choice = ui.open_select({ name = "resize-choice", parent = parent, rows = { "a", "b" }, height = 4 }),
      }

      local before = {}
      for name, handle in pairs(handles) do
        local config = vim.api.nvim_win_get_config(handle.win)
        before[name] = { width = config.width, height = config.height }
      end

      vim.o.columns, vim.o.lines = 80, 24
      vim.api.nvim_exec_autocmds("VimResized", {})

      for _, name in ipairs({ "input", "confirm", "preview", "help", "select", "choice" }) do
        local config = vim.api.nvim_win_get_config(handles[name].win)
        assert.is_true(config.width < before[name].width)
      end
      assert.equals(before.input.height, vim.api.nvim_win_get_config(handles.input.win).height)
      assert.equals(before.confirm.height, vim.api.nvim_win_get_config(handles.confirm.win).height)
      assert.equals(before.choice.height, vim.api.nvim_win_get_config(handles.choice.win).height)
      assert.is_true(vim.api.nvim_win_get_config(handles.preview.win).height < before.preview.height)
      assert.is_true(vim.api.nvim_win_get_config(handles.help.win).height < before.help.height)
      assert.is_true(vim.api.nvim_win_get_config(handles.select.win).height < before.select.height)
    end)
  end)

  describe("small screens", function()
    it("opens every screen inside a small editor", function()
      vim.o.columns, vim.o.lines = 12, 8
      local parent = vim.api.nvim_get_current_win()
      local handles = {
        ui.open_input({ name = "small-input", parent = parent, prompt = "Filter" }),
        ui.open_confirm({ name = "small-confirm", parent = parent, lines = { "a", "b", "c" } }),
        ui.open_preview({ name = "small-preview", parent = parent, header = "h", body = "b" }),
        ui.open_help({ name = "small-help", parent = parent, rows = { { "j", "次" } } }),
        ui.open_select({ name = "small-select", parent = parent, rows = { "a" } }),
      }
      for _, handle in ipairs(handles) do
        assert.is_true(vim.api.nvim_win_is_valid(handle.win))
        local config = vim.api.nvim_win_get_config(handle.win)
        assert.is_true(config.width >= 1)
        assert.is_true(config.height >= 1)
        assert.is_true(config.row >= 0)
        assert.is_true(config.col >= 0)
        assert.is_true(config.col + config.width <= vim.o.columns)
        assert.is_true(config.row + config.height <= vim.o.lines)
      end
    end)
  end)
end)
