#!/bin/bash
# Build OpenRouterFusion.app — native SwiftUI macOS chat client
set -eo pipefail
cd "$(dirname "$0")"

APP="OpenRouterFusion.app"
CONTENTS="${APP}/Contents"

echo "Building release binary..."
swift build -c release

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp ".build/release/OpenRouterFusion" "${CONTENTS}/MacOS/OpenRouterFusion"

# Copy Resources (ModelConfig.json + openrtr-owl)
cp -R Resources/* "${CONTENTS}/Resources/" 2>/dev/null || true

cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>OpenRouterFusion</string>
    <key>CFBundleDisplayName</key>       <string>OpenRouterFusion</string>
    <key>CFBundleIdentifier</key>        <string>dev.risingtides.openrouter-fusion</string>
    <key>CFBundleVersion</key>           <string>2</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>OpenRouterFusion</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "Built $(pwd)/${APP}"
echo "  Binary:  ${CONTENTS}/MacOS/OpenRouterFusion"
echo "  Size:    $(du -sh "${APP}" | cut -f1)"
