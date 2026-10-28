local M = {}
local active = {}
function M.begin_save(buf)
  if active[buf] then
    return nil, "save already in progress"
  end
  local snapshot =
    { buf = buf, tick = vim.api.nvim_buf_get_changedtick(buf), lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) }
  active[buf] = snapshot
  return snapshot
end
function M.finish_save(snapshot, success)
  if active[snapshot.buf] ~= snapshot then
    return false
  end
  active[snapshot.buf] = nil
  if not vim.api.nvim_buf_is_valid(snapshot.buf) then
    return false
  end
  if success and vim.api.nvim_buf_get_changedtick(snapshot.buf) == snapshot.tick then
    vim.bo[snapshot.buf].modified = false
  end
  return true
end
return M
