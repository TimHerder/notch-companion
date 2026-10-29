#!/bin/bash
# Credential-free checks shared by GitHub CI and local release preparation.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Checks require macOS 26 or newer with Xcode installed." >&2
    exit 1
fi
if [[ ! -x /usr/bin/python3 ]] || ! command -v python3 >/dev/null || ! command -v node >/dev/null; then
    echo "Checks require system Python 3 and Python 3 / Node.js on PATH for the offline fixtures." >&2
    exit 1
fi

# A release must not inherit an opt-in account-backed test from the shell.
for TEST_FLAG in ${!NOTCH_RUN_@}; do
    unset "$TEST_FLAG"
done
echo "Running offline checks; installed-runtime and account-backed tests stay skipped."

# The stdio delegation fixture launches this product, including with swiftbuild.
xcrun swift build --product NotchCompanion
export NOTCH_TEST_APP_EXECUTABLE="$(xcrun swift build --show-bin-path)/NotchCompanion"
test -x "$NOTCH_TEST_APP_EXECUTABLE"
xcrun swift test
NOTCH_SKIP_HERMES_TESTS=1 python3 -B -m unittest discover -v -s Tests/Backend -p 'test_*.py'
python3 -B -m unittest discover -v -s Tests/Release -p 'test_*.py'
./scripts/build-app.sh
python3 -B scripts/release.py verify 'build/Notch Companion.app'
