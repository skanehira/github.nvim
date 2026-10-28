# github.nvim

GitHub Issue operations in Neovim, using the GitHub CLI. Requires Neovim 0.10.4 or later and `gh` authenticated for github.com. Denops and Deno are not required.

Install the plugin with your preferred plugin manager. With lazy.nvim:

```lua
{
  "skanehira/github.nvim",
  lazy = false,
  opts = {},
}
```

Alternatively, load the plugin and optionally call `require("github").setup()`; the initial release accepts no configuration keys. Run `:checkhealth github` to check the GitHub CLI and authentication. If authentication is needed, run `gh auth login --hostname github.com`.

Open a repository's issues with `:edit github://owner/repo/issues`. The corresponding `https://github.com/owner/repo/issues` URL also works. For example, use `ghs` to search and `K` to preview the current issue.
