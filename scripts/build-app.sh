#!/bin/sh
# 把 SwiftPM 产物组装成可双击运行的 .app。
#
# 产出：
#   dist/WebHub.app                       ← 唯一交付物（应用中心 + 所有站点窗口都在这个进程里）
#   dist/WebHub.app/Contents/Resources/
#       WebHubRunner.app                  ← 站点 shim 模板，首次点图标时被拷进各站点包
#
# 用法：
#   sh scripts/build-app.sh
#   WEBHUB_VERSION=1.2.1 sh scripts/build-app.sh
#   WEBHUB_SIGN_IDENTITY="WebHub Local Signing" sh scripts/build-app.sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/WebHub.app"
BUNDLE_ID="cn.webhub.launcher"
VERSION="${WEBHUB_VERSION:-1.2.1}"
if [ "${WEBHUB_SIGN_IDENTITY+x}" = x ]; then
    SIGN_IDENTITY="$WEBHUB_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"WebHub Local Signing"'; then
    SIGN_IDENTITY="WebHub Local Signing"
else
    SIGN_IDENTITY="-"
fi

cd "$ROOT"

echo "==> 编译"
sh "$ROOT/scripts/build.sh" -c release
BIN_DIR="$(sh "$ROOT/scripts/build.sh" -c release --show-bin-path)"

# 打包在临时目录完成，最后整体替换：避免 Finder 在中途缓存到「没有图标」的半成品
STAGING="$(mktemp -d "$ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

APP_DIR="$STAGING/WebHub.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
mkdir -p "$CONTENTS/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

echo "==> 组装资源"
cp "$BIN_DIR/WebHub" "$CONTENTS/MacOS/WebHub"
chmod +x "$CONTENTS/MacOS/WebHub"
xcrun install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/WebHub"
cp "$ROOT/Sources/WebHub/Resources/zh-CN.json" "$CONTENTS/Resources/zh-CN.json"
# Let macOS discover the app's supported languages through standard bundle resources.
mkdir -p "$CONTENTS/Resources/en.lproj" "$CONTENTS/Resources/zh-Hans.lproj"
printf '"CFBundleDisplayName" = "WebHub";\n' > "$CONTENTS/Resources/en.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "WebHub";\n' > "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings"
cat >> "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "允许你在 WebHub 中为网页会议及其他站点功能使用摄像头。";
"NSMicrophoneUsageDescription" = "允许你在 WebHub 中为网页会议及其他站点功能使用麦克风。";
STRINGS
[ -f "$ROOT/Resources/WebHub.icns" ] || { echo "✗ 缺少 Resources/WebHub.icns" >&2; exit 1; }
cp "$ROOT/Resources/WebHub.icns" "$CONTENTS/Resources/WebHub.icns"
if [ -f "$ROOT/LICENSE" ]; then
    cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
fi

# 内嵌站点 shim。RunnerPackager 运行时只从这里拷二进制，
# 所以这个嵌套 app 的 Info.plist 只是占位（真正的站点 plist 在运行时生成）。
SHIM_APP="$CONTENTS/Resources/WebHubRunner.app"
mkdir -p "$SHIM_APP/Contents/MacOS"
cp "$BIN_DIR/WebHubRunner" "$SHIM_APP/Contents/MacOS/WebHubRunner"
chmod +x "$SHIM_APP/Contents/MacOS/WebHubRunner"

cat > "$SHIM_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WebHubRunner</string>
    <key>CFBundleIdentifier</key>
    <string>cn.webhub.runner.template</string>
    <key>CFBundleName</key>
    <string>WebHubRunner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WebHub</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>WebHub</string>
    <key>CFBundleDisplayName</key>
    <string>WebHub</string>
    <key>SUFeedURL</key>
    <string>https://github.com/luckalphie/WebHub/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>wofTIhLvgQEaDauho0UXR6/HPZ/Dq64hTK7J9nBXYAg=</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleIconFile</key>
    <string>WebHub.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>Use the camera for video calls and other features on sites you authorize in WebHub.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Use the microphone for calls and other features on sites you authorize in WebHub.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 自建 WebView 浏览器要能打开任意站点（含内网 http），不能受 ATS 限制 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Release 产物也可能带着指向本机源码的调试符号，去掉再签名，免得对外分发时泄露路径
xcrun strip -S "$CONTENTS/MacOS/WebHub" 2>/dev/null || true
xcrun strip -S "$SHIM_APP/Contents/MacOS/WebHubRunner" 2>/dev/null || true

echo "==> 签名（${SIGN_IDENTITY}）"
# 先内层后外层，顺序反了外层签名会把内层的签名作废
codesign --force --sign "$SIGN_IDENTITY" "$SHIM_APP"
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"

mkdir -p "$(dirname -- "$APP")"
rm -rf "$APP"
mv "$APP_DIR" "$APP"
touch "$APP"

echo "==> 完成: $APP"
du -sh "$APP"
