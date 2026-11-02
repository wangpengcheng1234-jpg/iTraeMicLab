#!/bin/bash
# 编译并打包 iTraeMicLab.app（无需 Xcode，仅用 Command Line Tools）
set -e
cd "$(dirname "$0")"

APP="iTraeMicLab.app"
ARCH="$(uname -m)"
VERSION="1.3"
BUILD="$(date +%Y%m%d%H%M)"
mkdir -p .build
# 必须显式指定 deployment target：否则 swiftc 会把 minos 设成 SDK 版本，
# 导致 LaunchServices 报“不能与此版本的 macOS 配合使用”。
swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos14.0" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 14.0 \
    MicLabApp.swift -o .build/iTraeMicLab

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/iTraeMicLab "$APP/Contents/MacOS/iTraeMicLab"
if [ -f MicLab.icns ]; then
    cp MicLab.icns "$APP/Contents/Resources/MicLab.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>iTraeMicLab</string>
    <key>CFBundleIdentifier</key><string>local.itrae.miclab</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>iTraeMicLab</string>
    <key>CFBundleDisplayName</key><string>iTrae MicLab 监听台</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>MicLab</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>iTraeMicLab 需要访问麦克风，用于实时监听与降噪处理。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "已生成 $APP"
