# github.nvim

GitHub Issues, pull request lists, and Projects v2 boards in Neovim, using the GitHub CLI. Requires Neovim 0.10.4 or later, Git, and `gh` authenticated for github.com. Denops and Deno are not required.

## Install

With lazy.nvim:

```lua
{
  "skanehira/github.nvim",
  lazy = false,
  opts = {},
}
```

Alternatively, load the plugin and optionally call `require("github").setup()`. Setup accepts `nil`, an empty table, or the `projects` settings described under [Projects](#projects). Run `:checkhealth github` to check the CLI and authentication. To authenticate:

```sh
gh auth login --hostname github.com
```

## Use

Open lists for the current checkout's Git origin:

```vim
:GitHub issues
:GitHub pulls
```

Or specify a repository without a local checkout:

```vim
:GitHub issues owner/repo
:GitHub pulls owner/repo
```

Both lists initially show open items, up to 30 results. Press `ghs` and use `state:closed` for closed items or `is:merged` for merged PRs. Pull request lists support `ghs`, `K`, `<C-j>` / `<C-k>`, `ghy`, and `<C-o>`; PR editing and review are future work.

Direct `:edit github://owner/repo/issues` and `:edit github://owner/repo/pulls` work too, as do their corresponding GitHub HTTPS URLs.

| Key | Issue list | Comment list |
| --- | --- | --- |
| `ghs` | Search; use `state:closed` for closed Issues | — |
| `K` | Preview the full body | Preview the full body |
| `ghe` | Edit the body | Edit the comment |
| `ght` | Edit the title | — |
| `ghn` | Create an Issue | Post a comment |
| `ghc` / `gho` | Close / reopen | — |
| `gha` / `ghl` | Edit assignees / labels | — |
| `ghm` | Open comments | — |
| `<C-j>` / `<C-k>` | Toggle the row and move down / up | Same |
| `ghy` | Copy selected URLs, or the cursor row | Same |
| `<C-o>` | Open selected URLs in a browser | Same |

Issue body buffers also provide `ght`, `gha`, `ghl`, and `ghm`. Body, comment, and attribute navigation offers the current window, a split, a vertical split, or a new tab. Previews reuse a Markdown window while keeping focus in the list; press `q` in the preview to close it. Search opens a one-line buffer: Enter applies, and Normal-mode `q` or `<C-c>` cancels.

Use `:write` to save an editing buffer. Issue creation offers Markdown templates, then opens the gh terminal for the title and other options. Successful creation offers editing, URL copy, and browser actions. Failure or an unknown result retains the draft. Changes made during saving remain unsent and modified.

Public buffers:

```text
github://owner/repo/issues
github://owner/repo/pulls
github://owner/repo/issues/new
github://owner/repo/issues/123
github://owner/repo/issues/123/assignees
github://owner/repo/issues/123/labels
github://owner/repo/issues/123/comments
github://owner/repo/issues/123/comments/new
github://owner/repo/issues/123/comments/456
```

Assignees and labels use one name per line; an empty buffer clears the attribute. The final comment path uses a numeric comment database ID.

Every public buffer can omit `owner/repo/`, for example `:edit github://issues`, `:edit github://pulls`, or `:edit github://issues/123/comments`. The current directory's Git origin is resolved and the buffer is replaced with the same form under `github://owner/repo/`. If the origin cannot be resolved, an error is shown and the empty buffer stays open; run `:edit` to retry. The HTTPS URLs cannot omit the repository. Projects use float windows and have no public buffer URI.

Find the first PR associated with a commit:

```vim
:GitHub related-pr HEAD
:GitHub related-pr owner/repo commit
```

The first form uses the current checkout's origin. `:GhGetAssociatedPullRequest` remains available as a compatibility alias. The explicit form works without a checkout. Run `:help github` for the full manual, or `:help github-buffer-issue-list` for a specific buffer. The [help file](doc/github.txt) documents each URI, Plug mapping, highlight group, filetype, and User event.

## Projects

Projects v2 boards are shown in floating windows. Only github.com is supported; `gh` must be authenticated, and some Projects operations also require the `project` scope.

Open the authenticated user's Project list, or a user's or organization's list:

```vim
:GitHub projects
:GitHub projects owner
```

Open a board directly. A numeric first argument is a Project number:

```vim
:GitHub projects owner 12
:GitHub projects 12
```

`@me` means the authenticated user. Projects have no `github://` URI.

| Key | Project list | Board | Field editor |
| --- | --- | --- | --- |
| `j` / `k` | Select Project | Select item in the column | Select field |
| `h` / `l` | — | Previous / next column | — |
| `H` / `L` | — | First / last column | — |
| `g` / `G` | — | First / last item | — |
| `<CR>` | Open board | Open Issue, PR, or draft | Edit field |
| `K` | — | Preview body | — |
| `ghs` | — | Change filter | — |
| `ghe` | — | Edit fields | — |
| `ghn` | — | Add existing Issue/PR or draft | — |
| `ghd` | — | Delete item from Project | — |
| `r` | Reload | Reload | — |
| `?` | — | Key help | — |
| `q` / `<Esc>` | Close | Close board and children | Close editor |

Single-select options use `j` / `k` and `<CR>` to apply, with a final `値を解除` entry to clear the value. Text, number, and date fields use a one-line input: `<CR>` applies, `<C-c>` cancels, and an empty input clears the field. Number and date values are validated before sending.

Add an existing Issue/PR by URL or `owner/repo#number`, or create a draft Issue with a title and an optional Markdown body; `<C-s>` adds the draft body. Delete confirmation uses `y` to delete and `n` / `q` / `<Esc>` to cancel; deletion removes only the item from the Project, not the Issue or PR.

Configure Projects with `setup`:

```lua
{
  "skanehira/github.nvim",
  lazy = false,
  opts = {
    projects = {
      group_by = "Status", -- single-select field used for columns
      column_width = 36, -- 20-80; minimum width, columns auto-fit
      max_items = 1000, -- 1-10000
    },
  },
}
```

`group_by` defaults to `Status`; if no single-select field matches, the first one is used, and a Project without one is shown as a single column. Other keys and invalid values are rejected without applying part of the settings. See `:help github-projects` for all keys and limits.

## Scope

Only github.com is supported. Lists show up to 30 Issues/PRs or 100 comments, without page navigation. Attributes are fetched completely using internal pagination. Issue rows align by display width and abbreviate long titles, assignees after the first two, and labels after the first three; full data remains available for editing.

Clipboard writes use the `+` register. Neovim cannot reliably confirm provider completion, so the plugin reports the requested count and an unconfirmed result. Detectable failures are reported separately.

Project lists show at most 100 open Projects; fields are limited to the first 50 and views to the first 10. Items are fetched up to `max_items` without page navigation, and truncation is displayed. Project views are not switched or saved, and item reordering, archiving, multi-select and iteration editing, and creating or editing Projects or fields are not included. Built-in fields such as Title, Assignees, and Labels are edited through the Issue operations.

Project writes update the local board from the response and do not reload automatically; `r` fetches the current state. Reads immediately after a write can be stale for a few seconds. Filters are evaluated by GitHub, so a filter that matches no items is shown as a successful empty result. Redacted items can be deleted from the Project but cannot be previewed, moved, or opened; draft Issues have no URL.

Completion, Actions, PR review, Gists, repository-file browsing, and README buffers are not included. Actions and review integration are planned for a later release.

## License

[MIT](LICENSE). Ported from [denops-gh.vim](https://github.com/skanehira/denops-gh.vim).
