local function keys(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("preview and search views", function()
  local view
  before_each(function()
    view = require("github.core.view")
    vim.cmd("enew")
  end)
  after_each(function()
    vim.cmd("stopinsert")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only!")
    package.loaded["github.core.view"] = nil
  end)

  for _, kind in ipairs({ "preview", "search" }) do
    local mode = kind
    it("restores ordinary buffer window settings after leaving " .. mode, function()
      require("github.core.navigation").setup()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      if mode == "preview" then
        view.preview("body")
        vim.api.nvim_set_current_win(vim.fn.bufwinid("github:preview"))
      else
        view.search(vim.api.nvim_get_current_buf(), "state:open", function() end)
      end
      assert.same({ false, false, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
      assert.equals("wipe", vim.bo.bufhidden)
      vim.cmd("stopinsert")
      vim.cmd("enew!")
      assert.same({ true, true, true, false }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end)
  end
  for _, kind in ipairs({ "preview", "search" }) do
    local mode = kind
    it("inherits normal window settings from a managed source for " .. mode, function()
      require("github.core.navigation").setup()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      require("github.core.navigation").configure(vim.api.nvim_get_current_buf(), "gh-issues")
      if mode == "preview" then
        view.preview("body")
        vim.api.nvim_set_current_win(vim.fn.bufwinid("github:preview"))
      else
        view.search(vim.api.nvim_get_current_buf(), "state:open", function() end)
      end
      assert.same({ false, false, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
      vim.cmd("stopinsert")
      vim.cmd("enew!")
      assert.same({ true, true, true, false }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end)
  end
  it("reuses the Markdown preview in the current tab and returns focus to the source", function()
    local source = vim.api.nvim_get_current_win()
    vim.wo.wrap, vim.wo.number = true, true
    view.preview("first\r\nsecond")
    assert.equals(source, vim.api.nvim_get_current_win())
    local buf = vim.fn.bufnr("github:preview")
    local win = vim.fn.bufwinid(buf)
    assert.same({ "first", "second" }, lines(buf))
    assert.equals("markdown", vim.bo[buf].filetype)
    assert.equals(false, vim.bo[buf].modifiable)
    assert.equals(true, vim.bo[buf].readonly)
    assert.equals(false, vim.wo[win].wrap)
    assert.equals(true, vim.wo[source].wrap)
    assert.equals(true, vim.wo[source].number)
    view.preview("replacement")
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(win, vim.fn.bufwinid(buf))
    assert.same({ "replacement" }, lines(buf))
    vim.api.nvim_set_current_win(win)
    keys("q")
    assert.equals(false, vim.api.nvim_buf_is_valid(buf))
    assert.equals(source, vim.api.nvim_get_current_win())
  end)

  it("opens another preview window when the shared buffer is only visible in another tab", function()
    view.preview("one")
    local first_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local source = vim.api.nvim_get_current_win()
    view.preview("two")
    assert.equals(source, vim.api.nvim_get_current_win())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(first_tab))
    vim.cmd("tabclose")
  end)

  it("confirms edited search in a one-line buffer and restores the original window", function()
    local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local answers, events = {}, {}
    local group = vim.api.nvim_create_augroup("view_test", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "gh_open_issue_search",
      callback = function()
        events[#events + 1] = { vim.api.nvim_buf_get_name(0):match("[^/]+$"), vim.bo.filetype }
      end,
    })
    view.search(source_buf, "state:open", function(value)
      answers[#answers + 1] = { value, vim.api.nvim_get_current_win() }
    end)
    local search = vim.api.nvim_get_current_buf()
    assert.equals("github:issues-search", vim.api.nvim_buf_get_name(search):match("[^/]+$"))
    assert.equals(1, vim.api.nvim_win_get_height(0))
    assert.same({ "state:open" }, lines(search))
    assert.same({ { "github:issues-search", "issue-search" } }, events)
    vim.api.nvim_buf_set_lines(search, 0, -1, false, { "state:closed label:bug" })
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.is_true(vim.wait(1000, function()
      return #answers == 1
    end))
    assert.equals(source_win, vim.api.nvim_get_current_win())
    assert.equals(false, vim.api.nvim_buf_is_valid(search))
    assert.same({ { "state:closed label:bug", source_win } }, answers)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("cancels using q and Ctrl-C and does not submit empty or unchanged searches", function()
    local source_buf = vim.api.nvim_get_current_buf()
    local results = {}
    for _, case in ipairs({
      { key = "q", value = "changed" },
      { key = "<C-c>", value = "changed" },
      { key = "<CR>", value = "" },
      { key = "<CR>", value = "state:open" },
    }) do
      view.search(source_buf, "state:open", function(value)
        results[#results + 1] = value == nil and "cancelled" or value
      end)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { case.value })
      vim.cmd("stopinsert")
      keys(case.key)
      assert.is_true(vim.wait(1000, function()
        return vim.api.nvim_get_current_buf() == source_buf
      end))
      assert.equals(source_buf, vim.api.nvim_get_current_buf())
    end
    assert.same({ "cancelled", "cancelled", "cancelled", "cancelled" }, results)
  end)

  it("cancels when its window is closed and does not leak window options to the source", function()
    local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.wo.wrap, vim.wo.list, vim.wo.number = true, true, true
    local results = {}
    view.search(source_buf, "state:open", function(value)
      results[#results + 1] = value or "cancelled"
    end)
    local search_buf = vim.api.nvim_get_current_buf()
    vim.cmd("stopinsert")
    vim.cmd("close!")
    assert.is_true(vim.wait(1000, function()
      return #results == 1
    end))
    assert.equals(source_win, vim.api.nvim_get_current_win())
    assert.equals(false, vim.api.nvim_buf_is_valid(search_buf))
    assert.same({ true, true, true }, { vim.wo.wrap, vim.wo.list, vim.wo.number })
    assert.same({ "cancelled" }, results)
  end)

  it("reuses an existing search for the same source without discarding its edited condition", function()
    local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local results = {}
    local callback = function(value)
      results[#results + 1] = value or "cancelled"
    end
    view.search(source_buf, "state:open", callback)
    local search_buf, search_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(search_buf, 0, -1, false, { "state:closed" })
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(source_win)
    view.search(source_buf, "state:open", callback)
    assert.equals(search_win, vim.api.nvim_get_current_win())
    assert.equals(search_buf, vim.api.nvim_get_current_buf())
    assert.same({ "state:closed" }, lines(search_buf))
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.same({ "state:closed" }, results)
  end)

  it("submits and cancels search through insert-mode keys", function()
    local source_buf = vim.api.nvim_get_current_buf()
    local results = {}
    view.search(source_buf, "state:open", function(value)
      results[#results + 1] = value or "cancelled"
    end)
    vim.cmd("stopinsert")
    keys("A label:bug<CR>")
    assert.is_true(vim.wait(1000, function()
      return #results == 1
    end))
    assert.equals(source_buf, vim.api.nvim_get_current_buf())
    assert.same({ "state:open label:bug" }, results)
    view.search(source_buf, "state:open", function(value)
      results[#results + 1] = value or "cancelled"
    end)
    vim.cmd("stopinsert")
    keys("A ignored<C-c>")
    assert.is_true(vim.wait(1000, function()
      return #results == 2
    end))
    assert.equals(source_buf, vim.api.nvim_get_current_buf())
    assert.same({ "state:open label:bug", "cancelled" }, results)
  end)

  for _, ending in ipairs({ "<CR>", "q" }) do
    local finish = ending
    it("returns to the invoking window when the same source buffer is shown twice using " .. ending, function()
      local buf, origin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      vim.api.nvim_set_current_win(origin)
      local results = {}
      view.search(buf, "state:open", function(value)
        results[#results + 1] = value or "cancelled"
      end)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "state:closed" })
      vim.cmd("stopinsert")
      keys(finish)
      assert.equals(origin, vim.api.nvim_get_current_win())
      assert.same({ finish == "q" and "cancelled" or "state:closed" }, results)
    end)
  end
  it("retargets an existing search to the last invoking window without losing the edited condition", function()
    local buf, first = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(first)
    local old_results, results = {}, {}
    view.search(buf, "state:open", function(value)
      old_results[#old_results + 1] = value or "cancelled"
    end)
    local search = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(search, 0, -1, false, { "state:closed" })
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(second)
    view.search(buf, "state:open", function(value)
      results[#results + 1] = value or "cancelled"
    end)
    assert.equals(search, vim.api.nvim_get_current_buf())
    assert.same({ "state:closed" }, lines(search))
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(0))
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.equals(second, vim.api.nvim_get_current_win())
    assert.same({ "state:closed" }, results)
    assert.same({}, old_results)
  end)
  it("compares a reused search against the newest caller condition", function()
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local results = {}
    view.search(buf, "state:open", function() end)
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(win)
    view.search(buf, "state:closed", function(value)
      results[#results + 1] = value or "cancelled"
    end)
    assert.same({ "state:open" }, lines(vim.api.nvim_get_current_buf()))
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.same({ "state:open" }, results)
  end)
  it("compares at submission time when a background result changes the successful condition", function()
    local condition, results = "state:open", {}
    view.search(vim.api.nvim_get_current_buf(), condition, function(value)
      results[#results + 1] = value or "cancelled"
    end, function()
      return condition
    end)
    condition = "state:closed"
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.same({ "state:open" }, results)
  end)
  it("replaces a search from another source and never submits to a closed source", function()
    local first_buf = vim.api.nvim_get_current_buf()
    local first, second = {}, {}
    view.search(first_buf, "one", function(value)
      first[#first + 1] = value or "cancelled"
    end)
    local original = vim.api.nvim_get_current_win()
    vim.cmd("wincmd p")
    vim.cmd("new")
    local second_buf = vim.api.nvim_get_current_buf()
    view.search(second_buf, "two", function(value)
      second[#second + 1] = value or "cancelled"
    end)
    assert.equals(false, vim.api.nvim_win_is_valid(original))
    assert.same({ "two" }, lines(vim.api.nvim_get_current_buf()))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "three" })
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.is_true(vim.wait(1000, function()
      return #second == 1
    end))
    assert.equals(second_buf, vim.api.nvim_get_current_buf())
    assert.same({ "cancelled" }, first)
    assert.same({ "three" }, second)
    view.search(second_buf, "four", function(value)
      second[#second + 1] = value or "cancelled"
    end)
    vim.api.nvim_buf_delete(second_buf, { force = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "five" })
    vim.cmd("stopinsert")
    keys("<CR>")
    assert.is_true(vim.wait(1000, function()
      return vim.fn.bufnr("github:issues-search") == -1
    end))
    assert.same({ "three" }, second)
  end)
end)
