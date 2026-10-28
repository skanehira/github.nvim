.PHONY: setup test test-file lint check

setup:
	./scripts/setup-test-deps.sh

test:
	./scripts/run-tests.sh
	./scripts/test-isolation.sh

test-file:
	@test -n "$(FILE)" || { echo 'Usage: make test-file FILE=path/to/file_spec.lua' >&2; exit 1; }
	./scripts/run-tests.sh "$(FILE)"

lint:
	luacheck lua scripts --no-color

check:
	stylua --check lua scripts
