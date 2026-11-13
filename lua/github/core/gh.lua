local M = {}

local function target_name(target)
  local parts = { target.host }
  if target.owner then
    parts[#parts + 1] = target.owner
  end
  if target.repo then
    parts[#parts + 1] = target.repo
  end
  return table.concat(parts, "/")
end

function M.new(run)
  run = run or require("github.core.process").run
  local function call(target, argv, stdin, graphql, callback)
    local name = target_name(target)
    run(argv, { stdin = stdin, cwd = target.cwd }, function(result)
      local function fail(reason, kind, status, errors)
        local failure = { target = name, reason = reason }
        if argv[5] == "--method" and argv[6] == "PATCH" then
          failure.kind = kind
        end
        if status then
          failure.status = status
        end
        if errors then
          failure.errors = errors
        end
        callback(nil, failure)
      end
      if not result then
        if vim.fn.executable("gh") == 0 then
          return fail("gh is not installed; install GitHub CLI (https://cli.github.com/)")
        end
        return fail("GitHub process failed to start")
      end
      if result.code ~= 0 then
        local stderr = result.stderr or ""
        local status = tonumber(stderr:match("HTTP (%d%d%d)"))
        if result.code == 4 or status == 401 or stderr:find("gh auth login", 1, true) then
          return fail("gh is not authenticated; run gh auth login --hostname " .. target.host, "rejected", status)
        end
        local kind = status and status >= 400 and status < 500 and "rejected" or "unknown"
        return fail("GitHub request failed (exit " .. tostring(result.code) .. ")", kind, status)
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout)
      if not ok or type(decoded) ~= "table" then
        return fail("invalid JSON response")
      end
      if graphql and type(decoded.errors) == "table" and decoded.errors ~= vim.NIL and #decoded.errors > 0 then
        local messages = {}
        for _, item in ipairs(decoded.errors) do
          messages[#messages + 1] = type(item) == "table" and type(item.message) == "string" and item.message
            or tostring(item)
        end
        return fail("GraphQL errors returned", nil, nil, messages)
      end
      callback(decoded)
    end)
  end
  return {
    graphql = function(target, query, variables, callback)
      call(
        target,
        { "gh", "api", "graphql", "--hostname", target.host, "--input", "-" },
        vim.json.encode({ query = query, variables = variables }),
        true,
        callback
      )
    end,
    rest = function(target, method, endpoint, body, callback)
      local args = { "gh", "api", "--hostname", target.host, "--method", method, endpoint }
      if body ~= nil then
        vim.list_extend(args, { "--input", "-" })
      end
      call(target, args, body ~= nil and vim.json.encode(body) or nil, false, callback)
    end,
  }
end

function M.paginate(fetch, callback)
  local seen, items = {}, {}
  local function next_page(cursor)
    fetch(cursor, function(page, err)
      if not page then
        return callback(nil, err)
      end
      if type(page) ~= "table" or type(page.items) ~= "table" or not vim.islist(page.items) then
        return callback(nil, "invalid pagination items")
      end
      if type(page.pageInfo) ~= "table" or type(page.pageInfo.hasNextPage) ~= "boolean" then
        return callback(nil, "invalid pagination pageInfo")
      end
      vim.list_extend(items, page.items)
      local info = page.pageInfo
      if not info.hasNextPage then
        return callback(items)
      end
      local next_cursor = info.endCursor
      if type(next_cursor) ~= "string" or next_cursor == "" then
        return callback(nil, "pagination cursor missing")
      end
      if seen[next_cursor] then
        return callback(nil, "pagination cursor repeated")
      end
      seen[next_cursor] = true
      next_page(next_cursor)
    end)
  end
  next_page(nil)
end

return M
