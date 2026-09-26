# iCube — task entrypoints for the iOS/tvOS app.
#
# Lives here rather than at the repo root because this is the app: Project.swift,
# Tuist.swift and the generated iCube.xcworkspace are all in this directory, and
# `tuist generate` must run from it. The repo root is the Dolphin CMake tree.
#
#   cd Source/iOS/App && make testflight
#
.PHONY: help xcframework generate dev open lint format test testflight testflight-tvos \
	testflight-all release-dry clean mcp-install mcp-test mcp-smoke webserver-bench

# Repo root — BuildiOSXCFramework.py and ExportOptions/ live there, not here.
ROOT := $(shell git rev-parse --show-toplevel)

# --- 1Password secret resolution -------------------------------------------
# .env may hold `op://` REFERENCES rather than values. Sourcing it directly would
# export the literal string "op://..." into release.sh, which fails confusingly.
# When references are present, run release.sh under `op run`, which resolves them
# into the child process environment only — never to disk, and masked in output.
# With a plain .env (or none), RELEASE_RUNNER is empty and ordinary exported
# ASC_API_KEY_* variables work, so a flaky 1Password never blocks a release.
ENV_HAS_OP_REFS := $(shell test -f .env && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=op://' .env && echo 1)
ifeq ($(ENV_HAS_OP_REFS),1)
RELEASE_RUNNER := op run --env-file=.env --
else
RELEASE_RUNNER :=
endif

help:
	@echo "iCube tasks (run from Source/iOS/App):"
	@echo "  make xcframework  — build PVlibDolphin.xcframework (iOS + tvOS, device + sim)"
	@echo "  make generate     — tuist generate (needs the xcframework first)"
	@echo "  make test         — run iCubeTests on an iOS simulator (SIM=\"iPhone 17 Pro\")"
	@echo "  make dev          — generate + open the workspace"
	@echo "  make lint         — SwiftLint"
	@echo "  make format       — SwiftFormat (check only, no writes)"
	@echo "  make testflight   — archive + auto-bump build number + upload iOS to TestFlight"
	@echo "  make testflight-tvos — same, tvOS"
	@echo "  make testflight-all  — both, one after the other (never in parallel)"
	@echo "  make release-dry  — print the release commands without executing them"
	@echo "  make clean        — remove generated project + archives"
	@echo "  make mcp-install  — uv sync the Tools/mcp debug MCP project"
	@echo "  make mcp-test     — run Tools/mcp's pytest suite"
	@echo "  make mcp-smoke    — live smoke test against a device on iproxy (needs a game booted)"
	@echo "  make webserver-bench — WebDAV vs browser PUT vs multipart upload throughput (Bonjour or URL=http://ip/)"
	@echo ""
	@echo "First run on a fresh clone:"
	@echo "  make xcframework && make generate && make testflight"
	@echo ""
	@echo "TestFlight needs ASC_API_KEY_ID, ASC_API_ISSUER_ID, and one of"
	@echo "ASC_API_KEY_PATH / ASC_API_KEY_CONTENT. See .env.sample."
ifeq ($(ENV_HAS_OP_REFS),1)
	@echo "Secrets: resolving .env op:// references via 'op run'."
endif

# Must run BEFORE `generate`: tuist resolves the binary target eagerly, so
# generation fails on a fresh clone if the xcframework is missing.
xcframework:
	cd "$(ROOT)" && python3 BuildiOSXCFramework.py \
		--platforms OS64 SIMULATORARM64 TVOS SIMULATOR_TVOS

generate:
	tuist generate --no-open

dev: generate
	open iCube.xcworkspace

open: dev

lint:
	swiftlint lint --config "$(ROOT)/.swiftlint.yml"

format:
	swiftformat --lint --config "$(ROOT)/.swiftformat" .

# --- Release ----------------------------------------------------------------
# Wrap Scripts/release.sh, a local mirror of .github/workflows/testflight.yml.
# The build number auto-bumps to an epoch timestamp inside the script and is
# passed on the xcodebuild command line — no file to edit, no commit, no manual
# bump (iCube's version lives in Project.swift, not an xcconfig).

# Unit tests on the iOS simulator. CODE_SIGNING_ALLOWED=NO does NOT work here: the vendored
# Externals/MoltenVK-iOS xcframework is unsigned and current simulator runtimes refuse to dyld-load
# an unsigned image ("Trying to load an unsigned library"), so let the embed phase ad-hoc sign it.
# iCubeTests is iOS-only (no tvOS platform on the test target). 182 tests green on 2026-09-26.
SIM ?= iPhone 17 Pro
test:
	xcodebuild test -workspace iCube.xcworkspace -scheme "iCube (NJB)" \
	  -configuration "Debug (Non-Jailbroken)" -destination "platform=iOS Simulator,name=$(SIM)" \
	  -derivedDataPath build-Xcode-ios \
	  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""

testflight:
	$(RELEASE_RUNNER) ./Scripts/release.sh --channel testflight --platform ios

testflight-tvos:
	$(RELEASE_RUNNER) ./Scripts/release.sh --channel testflight --platform tvos

testflight-all:
	$(RELEASE_RUNNER) ./Scripts/release.sh --channel testflight --platform all

release-dry:
	$(RELEASE_RUNNER) ./Scripts/release.sh --channel testflight --platform all --dry-run

clean:
	rm -rf iCube.xcodeproj iCube.xcworkspace Derived "$(ROOT)/build/archives" "$(ROOT)/build/export"

# --- Debug MCP (Tools/mcp) ---------------------------------------------------
mcp-install:
	cd "$(ROOT)/Tools/mcp" && uv sync
mcp-test:
	cd "$(ROOT)/Tools/mcp" && uv run pytest -q
# Needs a device on `iproxy 8723 8723` with a game booted.
mcp-smoke:
	cd "$(ROOT)/Tools/mcp" && uv run python -m icube_debug.smoke

# --- Upload server benchmark ----------------------------------------------
# Open Settings on the device first so the server is up. URL=http://ip/ skips Bonjour.
webserver-bench:
	./Scripts/webserver_transfer_bench.sh $(if $(URL),--url $(URL),)
