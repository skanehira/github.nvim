local M = {}

-- TTL cache with single-flight loading. The loader runs once for concurrent
-- misses, and every waiter receives the same result. Entries expire so stale
-- candidates (users, labels, projects, field options) are refreshed.
local entries = {}
local inflight = {}
local DEFAULT_TTL = 300000

local function now()
  return vim.uv.now()
end

function M.get(key)
  local entry = entries[key]
  if entry and entry.expires > now() then
    return entry.value
  end
  entries[key] = nil
  return nil
end

function M.set(key, value, ttl)
  entries[key] = { value = value, expires = now() + (ttl or DEFAULT_TTL) }
end

function M.fetch(key, ttl, loader, callback)
  local value = M.get(key)
  if value ~= nil then
    return callback(value)
  end
  if inflight[key] then
    inflight[key][#inflight[key] + 1] = callback
    return
  end
  inflight[key] = { callback }
  loader(function(loaded, err)
    local waiters = inflight[key]
    inflight[key] = nil
    if loaded ~= nil then
      entries[key] = { value = loaded, expires = now() + (ttl or DEFAULT_TTL) }
    end
    for _, waiter in ipairs(waiters or {}) do
      waiter(loaded, err)
    end
  end)
end

function M.invalidate(key)
  entries[key] = nil
end

function M.clear()
  entries = {}
end

return M
