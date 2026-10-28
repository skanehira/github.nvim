local M = {}
local generations = {}
local monitored = {}
function M.begin(buf)
  if not monitored[buf] then
    monitored[buf] = true
    vim.api.nvim_create_autocmd("BufUnload", {
      buffer = buf,
      once = true,
      callback = function()
        generations[buf] = (generations[buf] or 0) + 1
        monitored[buf] = nil
      end,
    })
  end
  generations[buf] = (generations[buf] or 0) + 1
  return { buf = buf, generation = generations[buf] }
end
function M.apply(request, callback)
  if
    not vim.api.nvim_buf_is_valid(request.buf)
    or not vim.api.nvim_buf_is_loaded(request.buf)
    or generations[request.buf] ~= request.generation
  then
    return false
  end
  callback(request.buf)
  return true
end
return M
