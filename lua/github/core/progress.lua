local M = {}
local namespace = vim.api.nvim_create_namespace("github_progress")
function M.start(buf, label)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  local generation = (vim.b[buf].github_progress_generation or 0) + 1
  vim.b[buf].github_progress_generation = generation
  vim.b[buf].github_status = label
  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    id = 1,
    virt_text = { { label, "Comment" } },
    virt_text_pos = "right_align",
  })
  return { buf = buf, generation = generation }
end
function M.finish(token)
  if
    not token
    or not vim.api.nvim_buf_is_valid(token.buf)
    or not vim.api.nvim_buf_is_loaded(token.buf)
    or vim.b[token.buf].github_progress_generation ~= token.generation
  then
    return
  end
  vim.b[token.buf].github_status = nil
  vim.api.nvim_buf_clear_namespace(token.buf, namespace, 0, -1)
end
return M
