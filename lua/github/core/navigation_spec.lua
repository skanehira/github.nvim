local navigation

describe("GitHub buffer navigation", function()
  local old_select
  before_each(function()
    navigation = require("github.core.navigation")
    old_select = vim.ui.select
    navigation.setup()
  end)
  after_each(function()
    vim.ui.select = old_select
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! %bwipeout!")
  end)
  for _, command in ipairs({ "edit", "new", "vnew", "tabnew" }) do
    it("opens the captured target with " .. command, function()
      local source = vim.api.nvim_get_current_buf()
      local windows, tabs = #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages()
      vim.ui.select = function(_, _, callback)
        callback(command)
      end
      navigation.open({ kind = "issue_list", owner = "a", repo = "r" })
      assert.equals("github://a/r/issues", vim.api.nvim_buf_get_name(0))
      assert.equals(
        (command == "new" or command == "vnew") and windows + 1 or windows,
        #vim.api.nvim_tabpage_list_wins(0)
      )
      assert.equals(command == "tabnew" and tabs + 1 or tabs, #vim.api.nvim_list_tabpages())
      if command ~= "edit" then
        assert.is_true(vim.api.nvim_buf_is_valid(source))
      end
    end)
  end
  for _, command in ipairs({ "new", "vnew", "tabnew" }) do
    local chosen = command
    it("inherits the ordinary settings of a managed source into " .. command, function()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
      vim.ui.select = function(_, _, callback)
        callback(chosen)
      end
      navigation.open({ kind = "issue_list", owner = "a", repo = "r" })
      assert.equals("github://a/r/issues", vim.api.nvim_buf_get_name(0))
      vim.cmd("enew!")
      assert.same({ true, true, true, false }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end)
  end
  for _, command in ipairs({ "split", "vsplit", "tab split", "new", "vnew", "tabnew" }) do
    local split = command
    it("preserves native option inheritance when a managed buffer is split with :" .. command, function()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
      vim.cmd(split)
      vim.cmd("enew!")
      assert.same({ false, false, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end)
  end
  it("preserves native API split options after switching from another managed window", function()
    for _, split in ipairs({ "left", "right", "above", "below" }) do
      for _, enter in ipairs({ true, false }) do
        for _, managed in ipairs({ true, false }) do
          vim.cmd("silent! only!")
          vim.cmd("silent! %bwipeout!")
          local source = vim.api.nvim_get_current_win()
          local buf = vim.api.nvim_get_current_buf()
          vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
          if managed then
            navigation.configure(buf, "gh-issues")
          end
          vim.cmd("vnew")
          vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = false, false, false, true
          navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
          vim.api.nvim_set_current_win(source)
          local inherited = managed and { false, false, false, true } or { true, true, true, false }
          assert.same(inherited, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
          local win = vim.api.nvim_open_win(buf, enter, { split = split, win = source })
          vim.api.nvim_set_current_win(win)
          vim.cmd("enew!")
          assert.same(inherited, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
        end
      end
    end
  end)
  it("leaves API-created splits with Neovim native option inheritance", function()
    for _, enter in ipairs({ true, false }) do
      vim.cmd("silent! only!")
      vim.cmd("silent! %bwipeout!")
      navigation.setup()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
      local win = vim.api.nvim_open_win(0, enter, { split = "right", win = 0 })
      vim.api.nvim_set_current_win(win)
      vim.cmd("enew!")
      assert.same({ false, false, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end
  end)
  it("does not apply the current managed window settings to a split of another ordinary window", function()
    for _, enter in ipairs({ true, false }) do
      vim.cmd("silent! only!")
      vim.cmd("silent! %bwipeout!")
      local source = vim.api.nvim_get_current_win()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
      navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
      vim.cmd("vnew")
      local ordinary, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = false, true, false, true
      vim.api.nvim_set_current_win(source)
      local win = vim.api.nvim_open_win(buf, enter, { split = "right", win = ordinary })
      vim.api.nvim_set_current_win(win)
      vim.cmd("enew!")
      assert.same({ false, true, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    end
  end)
  it("cancels opening without altering the current buffer", function()
    vim.ui.select = function(_, _, callback)
      callback(nil)
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    local buf = vim.api.nvim_get_current_buf()
    navigation.open({ kind = "issue_edit", owner = "a", repo = "r", issue_number = 7 })
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.same({ "draft" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("applies virtual buffer options and restores the normal window settings", function()
    vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline = true, true, true, false
    local normal = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    navigation.configure(vim.api.nvim_get_current_buf(), "gh-issues")
    assert.same({ false, false, false, true }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
    assert.equals("hide", vim.bo.bufhidden)
    assert.equals("gh-issues", vim.bo.filetype)
    vim.api.nvim_set_current_buf(normal)
    assert.same({ true, true, true, false }, { vim.wo.number, vim.wo.list, vim.wo.wrap, vim.wo.cursorline })
  end)
end)
