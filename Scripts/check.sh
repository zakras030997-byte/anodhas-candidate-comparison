#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
xcrun swiftc "${CANDIDATE_FLAGS[@]}" -target "$(uname -m)-apple-macos13.3" Sources/Model.swift Sources/Engine.swift Sources/Transfer.swift Tests/Suite.swift -o .build/CalculationTests
.build/CalculationTests > Verification/calculation-tests.log
cat Verification/calculation-tests.log
