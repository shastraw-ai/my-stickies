#!/bin/bash
# Regenerates Resources/AppIcon.icns. Only needed if you edit tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift tools/make-icon.swift "$WORK/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "==> Resources/AppIcon.icns"
