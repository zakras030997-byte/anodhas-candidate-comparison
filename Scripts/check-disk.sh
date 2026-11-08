#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
xcrun swiftc "${CANDIDATE_FLAGS[@]}" -target "$(uname -m)-apple-macos13.3" Sources/Model.swift Sources/Engine.swift Sources/Disk.swift Tests/DiskSuite.swift -o .build/DiskTests
.build/DiskTests > Verification/disk-tests.log
cat Verification/disk-tests.log
