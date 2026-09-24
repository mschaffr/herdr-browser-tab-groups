#!/usr/bin/env bash
# Runs every test suite. Nothing touches your installation: the app under test runs on free ports with a
# temporary config against a fake herdr, the extension runs against a simulated Chrome, and the scripts
# run against a temporary $HOME. (The test app's icon may flash briefly in the menu bar.)
#
#   scripts/test.sh            all suites
#   scripts/test.sh unit|extension|integration
set -euo pipefail
cd "$(dirname "$0")/.."
suite="${1:-all}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

if [[ "$suite" == all || "$suite" == unit || "$suite" == integration ]]; then
  step "build"
  swift build 2>&1 | grep -E "error|warning: .*Sources" || true
  swift build >/dev/null   # fail the run on build errors
fi

if [[ "$suite" == all || "$suite" == unit ]]; then
  step "unit: Swift core (core-checks)"
  swift run -q core-checks
fi

if [[ "$suite" == all || "$suite" == extension ]]; then
  step "extension: background.js in a simulated Chrome"
  node --test tests/extension/*.test.mjs
fi

if [[ "$suite" == all || "$suite" == integration ]]; then
  step "integration: app, CLI, native host, scripts"
  (cd tests/integration && python3 -W ignore::ResourceWarning -m unittest discover)
fi

step "all passed"
