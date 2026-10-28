#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .deps
if [ ! -d .deps/plenary.nvim/.git ]; then
  git clone https://github.com/nvim-lua/plenary.nvim.git .deps/plenary.nvim
fi
git -C .deps/plenary.nvim fetch origin 74b06c6c75e4eeb3108ec01852001636d85a932b
git -C .deps/plenary.nvim checkout --detach 74b06c6c75e4eeb3108ec01852001636d85a932b
