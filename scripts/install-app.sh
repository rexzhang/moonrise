#!/bin/bash
# 安装 Moonrise.app 到 /Applications（LSUIElement 菜单栏 App，ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="/Applications/Moonrise.app"
BIN=".build/release/MoonriseBar"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Moonrise"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Moonrise</string>
    <key>CFBundleDisplayName</key>
    <string>Moonrise</string>
    <key>CFBundleIdentifier</key>
    <string>com.moonrise.app</string>
    <key>CFBundleExecutable</key>
    <string>Moonrise</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✅ 安装完成：$APP"
echo "   启动：open $APP"
