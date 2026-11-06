#!/bin/bash
# 安装 MoonRise.app 到 /Applications（LSUIElement 菜单栏 App，ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="/Applications/MoonRise.app"
BIN=".build/release/MoonRiseBar"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MoonRise"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MoonRise</string>
    <key>CFBundleDisplayName</key>
    <string>MoonRise</string>
    <key>CFBundleIdentifier</key>
    <string>com.rexzhang.moonrise</string>
    <key>CFBundleExecutable</key>
    <string>MoonRise</string>
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

echo "==> 签名（优先级：Developer ID > MoonRiseDev 自签 > ad-hoc）"
IDENT=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E 'Developer ID Application|MoonRiseDev' | head -1 \
  | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)
if [ -n "$IDENT" ]; then
  codesign --force --sign "$IDENT" --identifier com.rexzhang.moonrise "$APP"
  echo "✅ 已用签名身份：$IDENT（TCC 授权跨重建稳定）"
else
  codesign --force --sign - --identifier com.rexzhang.moonrise "$APP"
  echo "⚠️ 未找到 MoonRiseDev 证书：先运行 scripts/make-cert.sh 生成，"
  echo "   否则 TCC 权限会在每次重建后失效。本次已用 ad-hoc 签名。"
fi

echo "✅ 安装完成：$APP"
echo "   启动：open $APP"
