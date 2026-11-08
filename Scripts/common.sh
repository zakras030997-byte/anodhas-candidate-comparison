#!/bin/bash
set -euo pipefail
CANDIDATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CANDIDATE_ROOT"
if [ -n "${CANDIDATE_COMPARISON_SDK:-}" ]; then
  CANDIDATE_SDK="$CANDIDATE_COMPARISON_SDK"
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  CANDIDATE_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  CANDIDATE_SDK="$(xcrun --show-sdk-path)"
fi
mkdir -p .build/module-cache Verification
CANDIDATE_FLAGS=(-swift-version 5 -O -parse-as-library -sdk "$CANDIDATE_SDK" -module-cache-path "$CANDIDATE_ROOT/.build/module-cache")
