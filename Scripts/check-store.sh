#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
xcrun swiftc "${CANDIDATE_FLAGS[@]}" -target "$(uname -m)-apple-macos13.3" Sources/Model.swift Sources/Engine.swift Sources/Disk.swift Sources/Transfer.swift Sources/Store.swift Tests/StoreSuite.swift -o .build/StoreTests
.build/StoreTests
