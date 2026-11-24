#!/bin/bash
# Builds DesktopIconBilliards.app (release binary + Info.plist + icon + ad-hoc signature).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product DesktopIconBilliards
BIN=.build/release/DesktopIconBilliards

APP=build/DesktopIconBilliards.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DesktopIconBilliards"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DesktopIconBilliards</string>
    <key>CFBundleDisplayName</key><string>桌面图标台球</string>
    <key>CFBundleIdentifier</key><string>com.liuxiaogang.desktopiconbilliards</string>
    <key>CFBundleExecutable</key><string>DesktopIconBilliards</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.5.2</string>
    <key>CFBundleVersion</key><string>12</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>与同一局域网内的玩家连接，进行桌面图标台球游戏。</string>
    <key>NSBonjourServices</key><array><string>_dibilliards._tcp</string></array>
    <key>NSDesktopFolderUsageDescription</key><string>读取本机桌面文件的图标，用于游戏。</string>
</dict>
</plist>
PLIST

# Derive the Finder icon from the shared DeskPool artwork.
mkdir -p build
ICON_MASTER=assets/deskpool.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$ICON_MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$ICON_MASTER" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Remove filesystem metadata before applying the local ad-hoc signature.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built $APP"
