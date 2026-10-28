#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$(mktemp -d "${TMPDIR:-/tmp}/github-nvim-external-config.XXXXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
mkdir -p "$root/nvim"
printf '%s\n' 'let g:external_init_loaded=1' > "$root/nvim/init.vim"

for spec in all lua/github/test_environment_spec.lua; do
  for source in VIMINIT EXINIT XDG_CONFIG_DIRS; do
    case "$source" in
      VIMINIT) value='let g:external_init_loaded=1' ;;
      EXINIT) value='let g:external_init_loaded=1' ;;
      XDG_CONFIG_DIRS) value=$root ;;
    esac
    if [ "$spec" = all ]; then
      env -u VIMINIT -u EXINIT -u XDG_CONFIG_DIRS "$source=$value" ./scripts/run-tests.sh
    else
      env -u VIMINIT -u EXINIT -u XDG_CONFIG_DIRS "$source=$value" ./scripts/run-tests.sh "$spec"
    fi
  done
done
