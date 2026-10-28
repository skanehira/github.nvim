local M = {}
local generations = {}
local monitored = {}
function M.begin(buf, label)
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
  label = label or "Loading..."
  return { buf = buf, generation = generations[buf], progress = require("github.core.progress").start(buf, label) }
end
function M.apply(request, callback, keep_progress)
  if
    not vim.api.nvim_buf_is_valid(request.buf)
    or not vim.api.nvim_buf_is_loaded(request.buf)
    or generations[request.buf] ~= request.generation
  then
    return false
  end
  if not keep_progress then
    require("github.core.progress").finish(request.progress)
  end
  callback(request.buf)
  return true
end
function M.finish(request)
  require("github.core.progress").finish(request.progress)
end
return M
