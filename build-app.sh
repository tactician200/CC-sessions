#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Universal (Apple silicon + Intel) by default; NATIVE_ONLY=1 builds just this
# Mac's architecture (faster for local iteration). The same flags go to
# --show-bin-path, or it points at the single-arch products.
if [ "${NATIVE_ONLY:-0}" = 1 ]; then ARCH_FLAGS=(); else ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "→ swift build -c release ${ARCH_FLAGS[*]:-}"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/ClaudeSessions"
APP="./build/ClaudeSessions.app"

if [ ! -f "$BIN" ]; then
    echo "✗ binary not found at $BIN"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ClaudeSessions"
chmod +x "$APP/Contents/MacOS/ClaudeSessions"

# App icon (Finder, Accessibility list, login items) — regenerate with scripts/make-icon.py
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# UI strings (en base + es), read through Bundle.main (L10n.swift)
for lproj in Sources/ClaudeSessions/Localization/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.tactician200.claude-sessions</string>
    <key>CFBundleName</key>
    <string>Claude Sessions</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Sessions</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>ClaudeSessions</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "✓ app: $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeSessions"))"
echo "→ open $APP"
