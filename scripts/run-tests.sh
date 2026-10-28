#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f .deps/plenary.nvim/lua/plenary/test_harness.lua ]; then
  echo 'Missing test dependency; run make setup first' >&2
  exit 1
fi
if [ "$#" -gt 1 ]; then
  echo 'Usage: run-tests.sh [spec-file]' >&2
  exit 1
fi
if [ "$#" -eq 1 ] && [ ! -f "$1" ]; then
  echo "Test file not found: $1" >&2
  exit 1
fi
root=$(mktemp -d "${TMPDIR:-/tmp}/github-nvim-test.XXXXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
export GITHUB_NVIM_TEST_ROOT="$root"
export XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data"
export XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
export XDG_CONFIG_DIRS="$root/config-dirs" XDG_DATA_DIRS="$root/data-dirs"
export GITHUB_NVIM_PLENARY_DIR="$PWD/.deps/plenary.nvim"
export GITHUB_NVIM_SPEC_FILE="${1:-}"
unset VIMINIT EXINIT
nvim --headless -u NONE --noplugin -l scripts/run-tests.lua
