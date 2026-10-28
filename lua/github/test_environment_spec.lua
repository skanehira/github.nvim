describe("isolated Neovim test environment", function()
  it("uses temporary standard paths and handles a buffer write in Neovim", function()
    local root = vim.env.GITHUB_NVIM_TEST_ROOT
    assert.is_string(root)
    assert.is_nil(vim.g.external_init_loaded)
    assert.equals(root .. "/config/nvim", vim.fn.stdpath("config"))
    assert.equals(root .. "/data/nvim", vim.fn.stdpath("data"))
    assert.equals(root .. "/state/nvim", vim.fn.stdpath("state"))
    assert.equals(root .. "/cache/nvim", vim.fn.stdpath("cache"))

    local path = root .. "/buffer.txt"
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buffer, path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "日本語", "second line" })
    vim.api.nvim_set_current_buf(buffer)
    vim.cmd("write")
    assert.same({ "日本語", "second line" }, vim.fn.readfile(path))
  end)
end)
