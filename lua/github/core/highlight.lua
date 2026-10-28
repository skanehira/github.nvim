local M = {}
local namespace = vim.api.nvim_create_namespace("github")

local function define()
  local colors = {
    gh_blue = { fg = "#84a0c6", ctermfg = 110 },
    gh_green = { fg = "#b4be82", ctermfg = 150 },
    gh_orange = { fg = "#e2a478", ctermfg = 216 },
    gh_red = { fg = "#ff5f5f", ctermfg = 203, bold = true },
  }
  local links = {
    gh_purple = "Constant",
    gh_issue_number = "gh_blue",
    gh_issue_open = "gh_green",
    gh_issue_closed = "gh_red",
    gh_issue_user = "gh_purple",
    gh_issue_labels = "gh_orange",
    gh_issue_comment_user = "gh_purple",
    gh_select = "ErrorMsg",
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
