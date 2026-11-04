#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipHistory"
VERSION="2.0.0"
DIST="$ROOT/dist"
APP_BUNDLE="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

# SwiftUI's macros need full Xcode; the Command Line Tools can't build this app.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# ── 1. Release build ──────────────────────────────────────────────────────────
echo "▸ Building release binary…"
cd "$ROOT"
swift build -c release

# ── 2. Generate app icon ──────────────────────────────────────────────────────
echo "▸ Generating icons…"
mkdir -p "$DIST"
swift scripts/generate-icons.swift "$DIST"

echo "▸ Compiling AppIcon.icns…"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"          # clean up intermediate files

# ── 3. Assemble .app bundle ───────────────────────────────────────────────────
echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME"   "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$DIST/AppIcon.icns"         "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClipHistory</string>

    <key>CFBundleIdentifier</key>
    <string>io.github.manan-santoki.cliphistory</string>

    <key>CFBundleName</key>
    <string>ClipHistory</string>

    <key>CFBundleDisplayName</key>
    <string>ClipHistory</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <key>CFBundleVersion</key>
    <string>$VERSION</string>

    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>

    <!-- Hide from Dock; lives only in the menu bar -->
    <key>LSUIElement</key>
    <true/>

    <key>NSPrincipalClass</key>
    <string>NSApplication</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSAccessibilityUsageDescription</key>
    <string>ClipHistory needs Accessibility access to paste clips and to open at your text cursor.</string>
</dict>
</plist>
PLIST

# ── 4. Ad-hoc code sign ───────────────────────────────────────────────────────
# A stable identity keeps Accessibility and Keychain approvals across rebuilds.
# An ad-hoc signature looks like a new app to macOS every time.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
echo "▸ Code signing (${IDENTITY:-ad-hoc})…"
codesign --force --sign "${IDENTITY:--}" "$APP_BUNDLE"

# ── 5. Create DMG with drag-to-Applications layout ────────────────────────────
echo "▸ Creating DMG…"
rm -f "$DMG"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -r "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname   "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format    UDZO \
    -o         "$DMG"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✓  $DMG"
echo "   Open the DMG and drag $APP_NAME.app → Applications to install."
