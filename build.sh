#!/bin/bash
# Builds my-stickies.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="my-stickies"
BUNDLE_ID="com.shastraw.my-stickies"
VERSION="1.0"
OUT="build/${APP_NAME}.app"

# The macOS 27 SDK implements SwiftUI's @State as a macro whose plugin ships only
# with Xcode, not Command Line Tools. Without it, fall back to the newest older SDK.
if [ -z "${SDKROOT:-}" ]; then
  TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
  if ! ls "$TOOLCHAIN"/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1; then
    FALLBACK="$(ls -d "$(xcrun --show-sdk-path)"/../MacOSX2[0-6].*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -n "$FALLBACK" ]; then
      export SDKROOT="$FALLBACK"
      echo "==> No SwiftUIMacros plugin; using $(basename "$SDKROOT")"
    fi
  fi
fi

echo "==> Compiling"
swift build -c release

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/${APP_NAME}" "$OUT/Contents/MacOS/${APP_NAME}"

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticTermination</key><false/>
	${ICON_KEY}
</dict>
</plist>
PLIST

# Ad-hoc signature keeps macOS from re-prompting on every launch.
codesign --force --deep --sign - "$OUT" 2>/dev/null || echo "    (codesign skipped)"

echo "==> Built $OUT"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$OUT" "/Applications/${APP_NAME}.app"
  echo "==> Installed to /Applications/${APP_NAME}.app"
fi
