local M = {}

local suffixes = {
  issue_list = "",
  issue_create = "/new",
  issue_edit = "/%d",
  issue_assignees = "/%d/assignees",
  issue_labels = "/%d/labels",
  comment_list = "/%d/comments",
  comment_create = "/%d/comments/new",
  comment_edit = "/%d/comments/%d",
}

local function positive(value)
  local n = tonumber(value)
  return n and n > 0 and n <= 9007199254740991 and n == math.floor(n)
end

local function parse_resource(resource, tail)
  if (resource ~= "issues" and resource ~= "pulls") or (resource == "pulls" and tail ~= "") then
    return nil
  end
  local kind, issue, comment
  if resource == "pulls" then
    kind = "pull_list"
  elseif tail == "" then
    kind = "issue_list"
  elseif tail == "/new" then
    kind = "issue_create"
  else
    local id, rest = tail:match("^/(%d+)(.*)$")
    if id and positive(id) then
      issue = tonumber(id)
      if rest == "" then
        kind = "issue_edit"
      elseif rest == "/assignees" then
        kind = "issue_assignees"
      elseif rest == "/labels" then
        kind = "issue_labels"
      elseif rest == "/comments" then
        kind = "comment_list"
      elseif rest == "/comments/new" then
        kind = "comment_create"
      else
        local cid = rest:match("^/comments/(%d+)$")
        if cid and positive(cid) then
          kind, comment = "comment_edit", tonumber(cid)
        end
      end
    end
  end
  if not kind then
    return nil
  end
  return { kind = kind, issue_number = issue, comment_id = comment }
end

function M.parse(value)
  if type(value) ~= "string" then
    return nil, "unsupported GitHub URI"
  end
  local path = value:match("^github://(.+)$") or value:match("^https://github%.com/(.+)$")
  local owner, repo, resource, tail
  if path then
    owner, repo, resource, tail = path:match("^([^/]+)/([^/]+)/([^/]+)(.*)$")
  end
  local target = owner and owner:match("^[%w][%w%-]*$") and repo:match("^[%w_.%-]+$") and parse_resource(resource, tail)
  if not target then
    return nil, "unsupported GitHub URI"
  end
  target.host, target.owner, target.repo = "github.com", owner, repo
  return target
end

function M.parse_current_repository(value)
  local resource, tail = value:match("^github://([^/]+)(.*)$")
  return resource and parse_resource(resource, tail) or nil
end

function M.format(target)
  if target.kind == "pull_list" then
    return "github://" .. target.owner .. "/" .. target.repo .. "/pulls"
  end
  local suffix = suffixes[target.kind]
  if not suffix then
    return nil
  end
  return "github://"
    .. target.owner
    .. "/"
    .. target.repo
    .. "/issues"
    .. string.format(suffix, target.issue_number, target.comment_id)
end

return M
