#!/usr/bin/env bash
# 在 WSL(Ubuntu 22.04) 安装 Flutter SDK —— 供本地跑**权威**的 flutter analyze / flutter test
#
# 🔴 为什么需要
#   本机 PATH 里的 `flutter` 指向**鸿蒙定制版**（`D:\flutter_flutter` = 3.27.5-ohos），
#   而**项目用的是官方 3.41.1**（`D:\flutter` 在 PATH 里，但被机器级 PATH 压在后面）。
#   ⚠️ 归因要准：不是「本机 Flutter 就是鸿蒙版」，而是「**裸调 `flutter` 会落到鸿蒙版**」
#      —— 两处 SDK 并存（详见 `references/verification-rules.md` §一）。
#   症状：`flutter analyze` 崩，CreateFile failed 231（无法创建子进程）
#   → 前端改动在本机**无法权威验证**，只能靠自建 analyzer
#     （它的注释自注「多报/少报」，口径与官方不一致 —— 已踩多次）。
#
# 🔴 为什么必须**锁版本**
#   `subosito/flutter-action@v2` 只写 `channel: stable` 时版本**随上游漂移**
#   → lint 规则集 / API 位置跟着变 →「本地绿 / CI 红」（或反之）会变成常态。
#   ✅ CI 已钉 **3.41.1**（2026-10-01 白哥定），本脚本的默认号与它**保持一致**。
#   📌 为什么是 3.41.1：项目的 SDK 就是 `D:\flutter` 的 3.41.1 stable
#      （见 `app/android/local.properties`），且项目文档早已认定
#      「只能在官方 3.41.1 上编译」（`docs/review/android-build-failed-wrong-flutter-sdk-2026-09-27.md`）。
#
# 用法（Windows 侧）：
#   LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc "tr -d '\r' < /mnt/e/CoEvo/scripts/setup/install_flutter_in_wsl.sh | bash"
#
# 换版本：FLUTTER_VERSION=3.47.5 bash install_flutter_in_wsl.sh
set -euo pipefail

FLUTTER_VERSION="${FLUTTER_VERSION:-3.41.1}"
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
