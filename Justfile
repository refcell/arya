# arya. `just` lists recipes.

set positional-arguments := true

# Command Line Tools builds intermittently lose the Swift Testing macro plugin; point the
# compiler at it explicitly when the toolchain ships it.
swift_flags := `d="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"; \
    [ -d "$d" ] && echo "-Xswiftc -plugin-path -Xswiftc $d" || true`

# At most this many parallel compile jobs per build (override with ARYA_JOBS).
jobs := env_var_or_default("ARYA_JOBS", "6")

# Every swift build or test runs in a machine-wide CI slot (etc/scripts/slot.sh).
slot := "etc/scripts/slot.sh"

alias b := build
alias t := test

default:
    @just --list

# Build every target and test target once (debug, testable; `just test` reuses it)
build *args:
    {{ slot }} swift build {{ swift_flags }} -j {{ jobs }} --build-tests "$@"

# Run tests, optionally filtered: just test AryaCoreTests
test filter='':
    #!/usr/bin/env bash
    set -euo pipefail
    {{ slot }} swift build {{ swift_flags }} -j {{ jobs }} --build-tests
    if [ -n "$1" ]; then {{ slot }} swift test {{ swift_flags }} --skip-build --filter "$1"
    else {{ slot }} swift test {{ swift_flags }} --skip-build; fi

# Format Swift sources in place
fmt:
    swift format format --in-place --recursive --configuration etc/swift-format.json \
      Package.swift Sources Tests

# Hygiene checks: format, line length, secrets, denylist, forbidden files, dependencies
tidy:
    etc/scripts/tidy.sh

# Install pre-commit and commit-msg hooks into the shared git dir
hooks:
    etc/scripts/install-hooks.sh

# Build the release app and bundle it to .build/Arya.app
app:
    etc/scripts/bundle-app.sh

# Build and launch the app bundle
run-app: app
    open .build/Arya.app

# Render every key app state offscreen to .build/snapshots (no window; decision 0038).
# Reuses .build/demo-home when present; `just demo --no-open` reseeds it.
snapshot:
    [ -d .build/demo-home ] || etc/scripts/demo.sh --no-open
    rm -rf .build/snapshots
    ARYA_SNAPSHOT_DIR="$PWD/.build/snapshots" ARYA_SNAPSHOT_HOME="$PWD/.build/demo-home" \
      {{ slot }} swift test {{ swift_flags }} -j {{ jobs }} --filter SnapshotTests
    @ls .build/snapshots

# Refresh docs/assets/app.png (the README screenshot) from the light run-with-approval snapshot
readme-screenshot: snapshot
    mkdir -p docs/assets
    sips -Z 1600 .build/snapshots/run-approval-light.png --out docs/assets/app.png >/dev/null
    @du -k docs/assets/app.png

# End-to-end scenario with the fake adapter and a temporary home (`just e2e --keep` keeps it)
e2e *args:
    etc/scripts/e2e.sh "$@"

# Seed .build/demo-home from etc/examples with weeks of history (look at it: `just snapshot`)
demo *args:
    etc/scripts/demo.sh "$@"

# Rebase, check, and push to main under push races: just publish 'Arya(App|Design)Tests'
publish filter:
    etc/scripts/publish.sh "{{ filter }}"

# Test the shell scripts (etc/scripts/test-publish.sh) against throwaway repositories
test-scripts:
    etc/scripts/test-publish.sh

# Everything CI runs
ci: tidy build test

# Run the adapter conformance suite against one adapter command
conformance cmd:
    ARYA_ADAPTER_CMD="{{ cmd }}" just test AdapterConformance

# Remove build products
clean:
    rm -rf .build
