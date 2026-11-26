#!/usr/bin/env bash
#
# Checks for the iOS app.
#
# Requirements: macOS with Xcode 26, the server repo at ./server and the lib
# repo at ./lib (CI checks both out there), plus the server's Python
# requirements.
#
# Usage:
#   app.sh lint  Run SwiftLint without blocking the pipeline.
#   app.sh test  Run the bootstrap server, Swift unit, integration and UI tests.
#
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_lint() {
    # SwiftLint is optional locally, but install it on CI if it is missing.
    command -v swiftlint >/dev/null || brew install swiftlint
    soft "swiftlint" swiftlint lint --reporter github-actions-logging HopChat-1
}

# The first available iPhone simulator, so CI does not depend on one model name.
first_iphone() {
    xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for d in devices[runtime]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit(0)
sys.exit(1)'
}

cmd_test() {
    # run_tests.sh (lib repo) uses these for the server, the app and the log.
    export PYTHON="${PYTHON:-$(command -v python)}"
    export XCODE_LOG="$OUT_DIR/xcodebuild.log"
    export HOPPIN_SERVER_DIR="${HOPPIN_SERVER_DIR:-$ROOT/server}"
    export HOPPIN_IOS_DIR="$ROOT"
    if [[ -z "${DESTINATION:-}" ]]; then
        DESTINATION="platform=iOS Simulator,id=$(first_iphone)"
        export DESTINATION
    fi
    echo "testing on: $DESTINATION"
    SKIP_PYTHON=1 lib/run_tests.sh
}

dispatch "$@"
