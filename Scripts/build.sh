#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [ "${CANDIDATE_SKIP_CHECKS:-0}" != 1 ]; then bash Scripts/check.sh; fi
CANDIDATE_RELEASE="$CANDIDATE_ROOT/releases/1.0.0"
CANDIDATE_APP="$CANDIDATE_RELEASE/Сравнение кандидатов.app"
mkdir -p "$CANDIDATE_RELEASE" "$CANDIDATE_APP/Contents/MacOS" "$CANDIDATE_APP/Contents/Resources"
for CANDIDATE_ARCH in arm64 x86_64; do
  mkdir -p ".build/$CANDIDATE_ARCH"
  xcrun swiftc "${CANDIDATE_FLAGS[@]}" -whole-module-optimization -target "$CANDIDATE_ARCH-apple-macos13.3" Sources/Model.swift Sources/Engine.swift Sources/Disk.swift Sources/Transfer.swift Sources/ImportView.swift Sources/Store.swift Sources/App.swift -o ".build/$CANDIDATE_ARCH/CandidateComparison"
done
xcrun lipo -create .build/arm64/CandidateComparison .build/x86_64/CandidateComparison -output "$CANDIDATE_APP/Contents/MacOS/CandidateComparison"
cp Resources/Info.plist "$CANDIDATE_APP/Contents/Info.plist"
xcrun swift -sdk "$CANDIDATE_SDK" -module-cache-path .build/module-cache Scripts/MakeIcon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$CANDIDATE_APP/Contents/Resources/AppIcon.icns"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements Resources/App.entitlements "$CANDIDATE_APP"
else
  codesign --force --options runtime --sign - --entitlements Resources/App.entitlements "$CANDIDATE_APP"
fi
codesign --verify --deep --strict "$CANDIDATE_APP"
plutil -lint "$CANDIDATE_APP/Contents/Info.plist"
xcrun lipo -archs "$CANDIDATE_APP/Contents/MacOS/CandidateComparison"
python3 Scripts/source_manifest.py
echo "$CANDIDATE_APP"
