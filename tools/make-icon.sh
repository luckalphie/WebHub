#!/bin/sh
# 重新生成 Resources/WebHub.icns。
#
# tools/makeicon.swift 只负责画 1024×1024 的 PNG（渐变底 + 四宫格），
# 这里补齐 PNG → iconset → icns 的流程。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/webhub-icon.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

echo "==> 绘制 PNG"
swift -O tools/makeicon.swift "$STAGING/icon-1024.png" >/dev/null

ICONSET="$STAGING/WebHub.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "$size" "$size" "$STAGING/icon-1024.png" \
        --out "$ICONSET/icon_${name}.png" >/dev/null
done

echo "==> 打包 icns"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/WebHub.icns"
echo "已更新 Resources/WebHub.icns"
