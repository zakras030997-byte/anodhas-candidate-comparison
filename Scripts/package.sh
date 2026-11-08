#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
CANDIDATE_RELEASE="$CANDIDATE_ROOT/releases/1.0.0"
CANDIDATE_APP="$CANDIDATE_RELEASE/Сравнение кандидатов.app"
CANDIDATE_STAGING="$CANDIDATE_ROOT/.build/installer-image"
CANDIDATE_DMG="$CANDIDATE_RELEASE/ANODHAS-Candidate-Comparison-1.0.0.dmg"
test -f "$CANDIDATE_APP/Contents/MacOS/CandidateComparison"
codesign --verify --deep --strict "$CANDIDATE_APP"
mkdir -p "$CANDIDATE_STAGING"
ditto "$CANDIDATE_APP" "$CANDIDATE_STAGING/Сравнение кандидатов.app"
if [ ! -L "$CANDIDATE_STAGING/Программы" ]; then ln -s /Applications "$CANDIDATE_STAGING/Программы"; fi
cp Resources/Установка.txt "$CANDIDATE_STAGING/Установка.txt"
hdiutil create -volname "Сравнение кандидатов" -srcfolder "$CANDIDATE_STAGING" -format UDZO -ov "$CANDIDATE_DMG"
hdiutil verify "$CANDIDATE_DMG" > Verification/dmg-verification.txt
python3 - "$CANDIDATE_DMG" <<'PYHASH'
from pathlib import Path
import sys,hashlib
p=Path(sys.argv[1]);p.with_name('SHA256SUMS.txt').write_text(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n')
PYHASH
echo "$CANDIDATE_DMG"
