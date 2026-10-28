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

function M.parse(value)
  if type(value) ~= "string" then
    return nil, "unsupported GitHub URI"
  end
  local path = value:match("^github://(.+)$") or value:match("^https://github%.com/(.+)$")
  local owner, repo, tail
  if path then
    owner, repo, tail = path:match("^([^/]+)/([^/]+)/issues(.*)$")
  end
  if not owner or not owner:match("^[%w][%w%-]*$") or not repo:match("^[%w_.%-]+$") then
    return nil, "unsupported GitHub URI"
  end
  local kind, issue, comment
  if tail == "" then
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
    return nil, "unsupported GitHub URI"
  end
  return { kind = kind, host = "github.com", owner = owner, repo = repo, issue_number = issue, comment_id = comment }
end

function M.format(target)
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
