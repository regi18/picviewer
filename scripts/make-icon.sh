#!/bin/sh
# Renders Resources/AppIcon.icns and docs/icon.png from scripts/make-icon.swift.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ROOT/Resources" "$ROOT/docs"
swift "$ROOT/scripts/make-icon.swift" "$WORK" "$ROOT/docs/icon.png"
iconutil -c icns "$WORK" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns and $ROOT/docs/icon.png"
