vim.opt.runtimepath:prepend(vim.uv.cwd())
vim.opt.runtimepath:prepend(vim.env.GITHUB_NVIM_PLENARY_DIR)

local harness = require("plenary.test_harness")
if vim.env.GITHUB_NVIM_SPEC_FILE and vim.env.GITHUB_NVIM_SPEC_FILE ~= "" then
  harness.test_file(vim.env.GITHUB_NVIM_SPEC_FILE)
else
  harness.test_directory("lua", { sequential = true })
end
