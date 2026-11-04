#!/bin/sh
# 从源码构建并直接运行。
#
# 注意：这是裸可执行文件，没有 bundle 标识。WebKit 在没有 bundle 时行为不可靠
# （窗口尺寸、cookie 存档、shim 拉起路径都假定自己跑在 .app 里）。
# 要完整验证功能，请用 sh scripts/build-app.sh 打包后运行。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 编译"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 运行 $BIN_DIR/WebHub"
echo "    （如需完整功能，改用 sh scripts/build-app.sh）"
exec "$BIN_DIR/WebHub" "$@"
