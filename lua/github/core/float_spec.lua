local float = require("github.core.float")

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

local function centered_row(config)
  return math.max(0, math.floor((vim.o.lines - config.height - 2) / 2))
end

local function centered_col(config)
  return math.max(0, math.floor((vim.o.columns - config.width - 2) / 2))
end

local function open_ratio(opts, width_ratio, height_ratio)
  opts.width, opts.height = float.target_size(width_ratio, height_ratio)
  return float.open(opts)
end

local function open_fixed_height(opts, width_ratio, height)
  opts.width = float.target_size(width_ratio, 1)
  opts.height = height
  opts.fixed_height = true
  return float.open(opts)
end

describe("float windows", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
  end)
  after_each(function()
    close_all()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("computes sizes from the editing area and centers floats with rounded borders", function()
    assert.same({ 82, 26 }, { float.target_size(0.7, 0.7) })
    assert.same({ 6, 18 }, { float.centered(82, 26) })

    local win, buf = open_ratio({ name = "projects-list:github.com:alice" }, 0.7, 0.7)
    local config = vim.api.nvim_win_get_config(win)
    assert.equals(82, config.width)
    assert.equals(26, config.height)
    assert.equals(6, config.row)
    assert.equals(18, config.col)
    assert.equals(8, #config.border)
    assert.equals("╭", config.border[1])
    assert.equals("nofile", vim.bo[buf].buftype)
    assert.equals("wipe", vim.bo[buf].bufhidden)
    assert.is_false(vim.bo[buf].swapfile)
    assert.is_false(vim.wo[win].wrap)
    assert.is_false(vim.wo[win].number)
    assert.is_false(vim.wo[win].relativenumber)
    assert.is_false(vim.wo[win].cursorline)
    assert.equals("no", vim.wo[win].signcolumn)
    assert.equals("0", vim.wo[win].foldcolumn)
    assert.is_false(vim.wo[win].list)
    assert.is_false(vim.wo[win].spell)
    assert.equals(0, vim.wo[win].scrolloff)
  end)

  it("restores focus to the parent, then the previous screen, then the original window", function()
    local original = vim.api.nvim_get_current_win()
    local list_win = open_ratio({ name = "list" }, 0.7, 0.7)
    local board_win = open_ratio({ name = "board", parent = list_win }, 0.9, 0.9)
    local editor_win = open_ratio({ name = "editor", parent = board_win }, 0.5, 0.6)
    assert.equals(editor_win, vim.api.nvim_get_current_win())
    assert.equals(3, #float_windows())
    assert.is_true(float.is_open("editor"))

    assert.is_true(float.close("editor"))
    assert.equals(board_win, vim.api.nvim_get_current_win())
    assert.is_false(float.is_open("editor"))
    assert.equals(2, #float_windows())

    assert.is_true(float.close("board"))
    assert.equals(list_win, vim.api.nvim_get_current_win())

    assert.is_true(float.close("list"))
    assert.equals(original, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())
    assert.is_false(float.close("list"))
    assert.is_nil(float.focus("list"))
  end)

  it("reuses a screen with the same name instead of opening a second one", function()
    local first_win, first_buf = open_ratio({ name = "board:1" }, 0.9, 0.9)
    local second_win, second_buf = open_ratio({ name = "board:1" }, 0.9, 0.9)
    assert.equals(first_win, second_win)
    assert.equals(first_buf, second_buf)
    assert.equals(1, #float_windows())
    assert.equals(first_win, vim.api.nvim_get_current_win())
  end)

  it("closes child screens when the parent screen is closed", function()
    local original = vim.api.nvim_get_current_win()
    local list_win = open_ratio({ name = "list" }, 0.7, 0.7)
    local board_win = open_ratio({ name = "board", parent = list_win }, 0.9, 0.9)
    local editor_win = open_ratio({ name = "editor", parent = board_win }, 0.5, 0.6)

    assert.is_true(float.close("list"))
    assert.is_false(vim.api.nvim_win_is_valid(board_win))
    assert.is_false(vim.api.nvim_win_is_valid(editor_win))
    assert.is_false(float.is_open("board"))
    assert.is_false(float.is_open("editor"))
    assert.equals(original, vim.api.nvim_get_current_win())
    assert.equals(0, #float_windows())
  end)

  it("closes child screens when the parent window is closed externally", function()
    local original = vim.api.nvim_get_current_win()
    local board_win = open_ratio({ name = "board" }, 0.9, 0.9)
    local editor_win = open_ratio({ name = "editor", parent = board_win }, 0.5, 0.6)

    vim.api.nvim_set_current_win(original)
    vim.api.nvim_win_close(board_win, true)
    assert.is_false(vim.api.nvim_win_is_valid(editor_win))
    assert.is_false(float.is_open("board"))
    assert.is_false(float.is_open("editor"))
    assert.equals(0, #float_windows())
    assert.equals(original, vim.api.nvim_get_current_win())
  end)

  it("repositions every float on VimResized and keeps them inside the screen", function()
    local list_win = open_ratio({ name = "list" }, 0.7, 0.7)
    local board_win = open_ratio({ name = "board", parent = list_win }, 0.9, 0.9)
    assert.equals(1, #vim.api.nvim_get_autocmds({ group = "github_float", event = "VimResized" }))

    vim.o.columns, vim.o.lines = 80, 24
    vim.api.nvim_exec_autocmds("VimResized", {})

    for _, win in ipairs({ list_win, board_win }) do
      local config = vim.api.nvim_win_get_config(win)
      assert.is_true(config.width >= 1)
      assert.is_true(config.height >= 1)
      assert.is_true(config.row >= 0)
      assert.is_true(config.col >= 0)
      assert.equals(centered_row(config), config.row)
      assert.equals(centered_col(config), config.col)
      assert.is_true(config.row + config.height <= vim.o.lines)
      assert.is_true(config.col + config.width <= vim.o.columns)
    end
    local config = vim.api.nvim_win_get_config(board_win)
    assert.equals(70, config.width)
    assert.equals(19, config.height)
    assert.equals(1, config.row)
    assert.equals(4, config.col)
  end)

  it("recomputes both width and height after VimResized when opened with target_size", function()
    vim.o.columns, vim.o.lines = 80, 24
    local width, height = float.target_size(0.9, 0.9)
    assert.same({ 70, 19 }, { width, height })
    local win = float.open({ name = "board:target", width = width, height = height })

    vim.o.columns, vim.o.lines = 120, 40
    vim.api.nvim_exec_autocmds("VimResized", {})

    local config = vim.api.nvim_win_get_config(win)
    assert.equals(105, config.width)
    assert.equals(32, config.height)
    assert.equals(centered_row(config), config.row)
    assert.equals(centered_col(config), config.col)
  end)

  it("clamps size and position to at least one cell on a tiny screen", function()
    vim.o.columns, vim.o.lines = 12, 5
    assert.same({ 1, 1 }, { float.target_size(0.01, 0.01) })
    assert.same({ 1, 4 }, { float.centered(1, 1) })

    local win = open_fixed_height({ name = "input" }, 0.01, 1)
    local config = vim.api.nvim_win_get_config(win)
    assert.equals(1, config.width)
    assert.equals(1, config.height)
    assert.equals(1, config.row)
    assert.equals(4, config.col)
  end)

  it("keeps fixed heights and proportional widths after VimResized", function()
    local win = open_fixed_height({ name = "confirm" }, 0.5, 3)
    vim.o.columns, vim.o.lines = 80, 24
    vim.api.nvim_exec_autocmds("VimResized", {})
    local config = vim.api.nvim_win_get_config(win)
    assert.equals(3, config.height)
    assert.equals(39, config.width)
    assert.equals(9, config.row)
    assert.equals(19, config.col)
  end)

  it("keeps stacks per tab page and leaves screens in other tabs alone", function()
    local first = open_ratio({ name = "board" }, 0.9, 0.9)
    vim.cmd("tabnew")
    assert.is_false(float.is_open("board"))
    local second = open_ratio({ name = "board" }, 0.9, 0.9)
    assert.is_true(first ~= second)
    assert.equals(1, #float_windows())
    assert.is_true(float.close("board"))
    assert.is_false(vim.api.nvim_win_is_valid(second))
    assert.is_true(vim.api.nvim_win_is_valid(first))
    vim.cmd("tabclose")
    assert.is_true(float.is_open("board"))
    assert.equals(first, vim.api.nvim_get_current_win())
  end)
end)
