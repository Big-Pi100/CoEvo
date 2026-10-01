#!/usr/bin/env bash
# 在 WSL(Ubuntu 22.04) 安装 Flutter SDK —— 供本地跑**权威**的 flutter analyze / flutter test
#
# 🔴 为什么需要
#   本机 Flutter 是**鸿蒙定制版**（3.27.5-ohos），`flutter analyze` 会崩：
#       CreateFile failed 231（无法创建子进程）
#   → 前端改动在本机**无法权威验证**，只能靠自建 analyzer
#     （它的注释自注「多报/少报」，口径与官方不一致 —— 已踩多次）。
#
# 🔴 为什么必须**锁版本**
#   CI 用的是 `subosito/flutter-action@v2` + `channel: stable`
#   → 版本**随上游漂移**（今天 3.47.5，明天可能 3.48.x）→ lint 规则集跟着变
#   →「本地绿 / CI 红」（或反之）会变成常态。
#   装上具体版本后，应把 CI 也锁到**同一版本**，口径才稳定。
#
# 用法（Windows 侧）：
#   LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc "tr -d '\r' < /mnt/e/CoEvo/scripts/setup/install_flutter_in_wsl.sh | bash"
#
# 换版本：FLUTTER_VERSION=3.48.0 bash install_flutter_in_wsl.sh
set -euo pipefail

FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.5}"
DEST="$HOME/flutter"
TARBALL="$HOME/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

echo "=== 目标: Flutter ${FLUTTER_VERSION} · 装到 ${DEST} ==="

if [ -x "$DEST/bin/flutter" ]; then
  echo "✅ 已存在，跳过安装"
  "$DEST/bin/flutter" --version 2>&1 | head -3
  exit 0
fi

echo
echo "=== 1/4 下载（断点续传 · 约 1 GB）==="
curl -L --retry 3 --retry-delay 5 -C - --progress-bar -o "$TARBALL" "$URL"
ls -la "$TARBALL"

echo
echo "=== 2/4 解压 ==="
tar -xf "$TARBALL" -C "$HOME"
ls -d "$DEST" >/dev/null && echo "  ✅ $DEST"

echo
echo "=== 3/4 git 安全目录 + PATH ==="
git config --global --add safe.directory "$DEST" 2>/dev/null || true
grep -q 'flutter/bin' "$HOME/.bashrc" 2>/dev/null \
  || echo 'export PATH="$HOME/flutter/bin:$PATH"' >> "$HOME/.bashrc"
echo "  ✅ 已写入 ~/.bashrc（新会话自动生效）"

echo
echo "=== 4/4 验证 ==="
export PATH="$DEST/bin:$PATH"
flutter --version
flutter config --no-analytics >/dev/null 2>&1 || true

echo
echo "✅ 安装完成。"
echo "   用法（Windows 侧）："
echo "     LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc 'cd /mnt/e/CoEvo/app && ~/flutter/bin/flutter analyze --no-fatal-infos'"
