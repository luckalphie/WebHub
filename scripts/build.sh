#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_MACOS_VERSION="$(swift package dump-package | plutil -extract platforms.0.version raw -o - -)"

# SwiftPM 可能把运行下限写入 SDK 标记，导致 AppKit 继续使用旧外观。
# 分别传入运行下限和实际 SDK 版本，保留旧系统兼容性并启用新系统控件样式。
exec swift build --sdk "$SDK_PATH" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$MIN_MACOS_VERSION" -Xlinker "$SDK_VERSION" "$@"
