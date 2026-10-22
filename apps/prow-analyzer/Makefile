# Local and GitHub Actions entry points for application builds and tests.
# For container builds, see image/container/prow-analyzer/Makefile.
.PHONY: build build--cli build--bot test test--unit test--integration check-tags clean help

SHELL   := /bin/bash
GO      ?= go
PKGS    ?= ./pkg/... ./cmd/...

SCRIPTS := ./scripts

# Build both binaries
build: build--cli build--bot

# Build CLI
build--cli:
	'$(GO)' build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build--bot:
	'$(GO)' build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run the full suite: unit (with coverage gate) then integration (mirrors CI ordering)
test: test--unit test--integration

# Gate all package and command unit tests together at 100% coverage.
test--unit:
	GO='$(GO)' PKGS='$(strip $(PKGS))' '$(SCRIPTS)/test--unit.sh'

# Integration tests: real HTTP servers and the async Handle() path, under -race.
test--integration:
	GO='$(GO)' PKGS='$(strip $(PKGS))' '$(SCRIPTS)/test--integration.sh'

# Fail if either build tag selects no tests (guards against silent 0-test runs)
check-tags:
	GO='$(GO)' PKGS='$(strip $(PKGS))' '$(SCRIPTS)/test--unit.sh' --check-only
	GO='$(GO)' PKGS='$(strip $(PKGS))' '$(SCRIPTS)/test--integration.sh' --check-only

# Clean build artifacts
clean:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    rm -f prow-analyzer--cli prow-analyzer--bot;\
	    rm -f coverage.out coverage.html;\
	true; }

# Help
help:
	@printf '%s\n' \
		'Prow Analyzer - Available targets:' \
		'  build             - Build both CLI and Bot binaries.' \
		'  build--cli        - Build CLI binary only.' \
		'  build--bot        - Build Bot binary only.' \
		'  test--unit        - Unit tests with 100% package coverage gate.' \
		'  test--integration - Integration tests (-tags integration -race).' \
		'  test              - Run unit then integration tests.' \
		'  check-tags        - Fail if a build tag selects no tests.' \
		'  clean             - Remove build artifacts and coverage reports.'
