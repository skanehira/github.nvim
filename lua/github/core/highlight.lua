local M = {}
local namespace = vim.api.nvim_create_namespace("github")

local function define()
  local colors = {
    gh_blue = { fg = "#84a0c6", ctermfg = 110 },
    gh_green = { fg = "#b4be82", ctermfg = 150 },
    gh_orange = { fg = "#e2a478", ctermfg = 216 },
    gh_red = { fg = "#ff5f5f", ctermfg = 203, bold = true },
    GitHubProjectsToolbar = { fg = "#e6edf3", bg = "#161b22" },
    GitHubProjectsHeader = { fg = "#e6edf3", bold = true },
    GitHubProjectsColumnHeader = { bg = "#161b22" },
    GitHubProjectsColumnBg = { bg = "#161b22" },
    GitHubProjectsColumn = { fg = "#e6edf3" },
    GitHubProjectsColumnSelected = { fg = "#ffffff", bg = "#1f6feb", bold = true },
    GitHubProjectsCard = { fg = "#e6edf3", bg = "#0d1117" },
    GitHubProjectsCardBorder = { fg = "#30363d" },
    GitHubProjectsCardSelected = { fg = "#e6edf3", bg = "#161b22" },
    GitHubProjectsCardSelectedBorder = { fg = "#58a6ff", bold = true },
    GitHubProjectsCardTitle = { fg = "#e6edf3", bold = true },
    GitHubProjectsNumber = { fg = "#8b949e" },
    GitHubProjectsMeta = { fg = "#8b949e" },
    GitHubProjectsProgress = { fg = "#3fb950" },
    GitHubProjectsProgressEmpty = { fg = "#30363d" },
    GitHubProjectsLabel = { fg = "#e6edf3", bg = "#30363d" },
    GitHubProjectsLabelMore = { fg = "#e6edf3", bg = "#30363d" },
    GitHubProjectsAvatar = { fg = "#ffffff", bg = "#1f6feb", bold = true },
    GitHubProjectsEmpty = { fg = "#8b949e" },
    GitHubProjectsColorGray = { fg = "#8b949e" },
    GitHubProjectsColorRed = { fg = "#f85149" },
    GitHubProjectsColorOrange = { fg = "#d29922" },
    GitHubProjectsColorYellow = { fg = "#d29922" },
    GitHubProjectsColorGreen = { fg = "#3fb950" },
    GitHubProjectsColorPink = { fg = "#db61a2" },
    GitHubProjectsColorPurple = { fg = "#a371f7" },
    GitHubProjectsColorBlue = { fg = "#58a6ff" },
  }
  local links = {
    gh_purple = "Constant",
    gh_issue_number = "gh_blue",
    gh_issue_open = "gh_green",
    gh_issue_closed = "gh_red",
    gh_pull_merged = "gh_purple",
    gh_issue_user = "gh_purple",
    gh_issue_labels = "gh_orange",
    gh_issue_comment_user = "gh_purple",
    gh_select = "ErrorMsg",
    GitHubProjectsRedacted = "Comment",
    GitHubProjectsError = "DiagnosticError",
    GitHubProjectsLoading = "DiagnosticWarn",
  }
  for name, definition in pairs(colors) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", definition, { default = true }))
  end
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

function M.setup()
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("github_highlight", { clear = true }),
    callback = define,
  })
end

function M.set(buf, spans)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, span in ipairs(spans) do
    if span[3] > span[2] then
      vim.api.nvim_buf_set_extmark(buf, namespace, span[1], span[2], { end_col = span[3], hl_group = span[4] })
    end
  end
end

return M
