local M = {}

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("github.nvim setup expects a table or nil", 2)
  end
  if opts then
    local key = next(opts)
    if key ~= nil then
      error("github.nvim setup does not support option: " .. tostring(key), 2)
    end
  end
  return {}
end

return M
