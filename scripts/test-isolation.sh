#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
VIMINIT='let g:external_init_loaded=1' ./scripts/run-tests.sh
VIMINIT='let g:external_init_loaded=1' ./scripts/run-tests.sh lua/github/test_environment_spec.lua
