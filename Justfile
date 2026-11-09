# arya. `just` lists recipes.

set positional-arguments := true

# Command Line Tools builds intermittently lose the Swift Testing macro plugin; point the
# compiler at it explicitly when the toolchain ships it.
swift_flags := `d="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"; \
    [ -d "$d" ] && echo "-Xswiftc -plugin-path -Xswiftc $d" || true`

alias b := build
alias t := test

default:
    @just --list

# Build every target and test target once (debug, testable; `just test` reuses it)
build *args:
    swift build {{ swift_flags }} --build-tests {{ args }}

# Run tests, optionally filtered: just test AryaCoreTests
test filter='':
    #!/usr/bin/env bash
    set -euo pipefail
    swift build {{ swift_flags }} --build-tests
    if [ -n "{{ filter }}" ]; then swift test {{ swift_flags }} --skip-build --filter "{{ filter }}"
    else swift test {{ swift_flags }} --skip-build; fi

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

# Build and launch the app on the in-memory preview workspace
app-preview: app
    open -n .build/Arya.app --args --preview

# End-to-end scenario with the fake adapter and a temporary home (`just e2e --keep` keeps it)
e2e *args:
    etc/scripts/e2e.sh {{ args }}

# Everything CI runs
ci: tidy build test

# Remove build products
clean:
    rm -rf .build
