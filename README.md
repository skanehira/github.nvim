# github.nvim

GitHub Issues and pull request lists in Neovim, using the GitHub CLI. Requires Neovim 0.10.4 or later, Git, and `gh` authenticated for github.com. Denops and Deno are not required.

## Install

With lazy.nvim:

```lua
{
  "skanehira/github.nvim",
  lazy = false,
  opts = {},
}
```

Alternatively, load the plugin and optionally call `require("github").setup()`. Setup accepts `nil` or an empty table; no configuration keys are supported in this release. Run `:checkhealth github` to check the CLI and authentication. To authenticate:

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

Find the first PR associated with a commit:

```vim
:GitHub related-pr HEAD
:GitHub related-pr owner/repo commit
```

The first form uses the current checkout's origin. `:GhGetAssociatedPullRequest` remains available as a compatibility alias. The explicit form works without a checkout. Run `:help github` for the full manual, or `:help github-buffer-issue-list` for a specific buffer. The [help file](doc/github.txt) documents each URI, Plug mapping, highlight group, filetype, and User event.

## Scope

Only github.com is supported. Lists show up to 30 Issues/PRs or 100 comments, without page navigation. Attributes are fetched completely using internal pagination. Issue rows align by display width and abbreviate long titles, assignees after the first two, and labels after the first three; full data remains available for editing.

Clipboard writes use the `+` register. Neovim cannot reliably confirm provider completion, so the plugin reports the requested count and an unconfirmed result. Detectable failures are reported separately.

Completion, Actions, PR review, Gists, repository-file browsing, and README buffers are not included. Actions and review integration are planned for a later release.

## License

[MIT](LICENSE). Ported from [denops-gh.vim](https://github.com/skanehira/denops-gh.vim).
