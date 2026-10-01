#!/usr/bin/env bash
# CoEvo 后端 · Linux x86_64 构建与打包（在 WSL Ubuntu 22.04 里执行）
#
# 为什么不在 Windows 上构建：产物是 PE(.exe)，部署机要 ELF。
# 为什么不用 GitHub Actions：仓库私有且本机无 token → artifact 拿不到（实测）。
# 🔑 WSL(22.04 / glibc 2.35) 构建 → 可在部署机(24.04 / glibc 2.39) 运行（向后兼容）。
#
# 用法（在 Windows 侧）：
#   LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc "tr -d '\r' < /mnt/e/CoEvo/scripts/deploy/build_linux_in_wsl.sh | bash"
#
# 产出：Windows 临时目录 coevo_deploy/（含二进制 + cefr_catalog.json + prompts/）
set -euo pipefail

REPO=/mnt/e/CoEvo
TARGET_DIR=/home/bigpi/coevo_target
OUT=/mnt/c/Users/Lenovo/AppData/Local/Temp/coevo_deploy

. "$HOME/.cargo/env"

echo "=== 1/4 构建（release）==="
cd "$REPO/backend"
cargo build --release --bin coevo_backend --target-dir "$TARGET_DIR"

BIN="$TARGET_DIR/release/coevo_backend"

echo
echo "=== 2/4 核验产物 ==="
file "$BIN"
ls -la "$BIN"

echo
echo "=== 3/4 strip + 组装部署包 ==="
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BIN" "$OUT/"
strip "$OUT/coevo_backend"
cp "$REPO/backend/cefr_catalog.json" "$OUT/"
cp -r "$REPO/backend/prompts" "$OUT/"

echo
echo "=== 4/4 清单 ==="
ls -la "$OUT"
echo "--- 合计 ---"
du -sh "$OUT"
echo
echo "--- 动态依赖（目标机需有对应 libc/libssl）---"
ldd "$OUT/coevo_backend" | head -10

echo
echo "✅ 完成。部署包在: $OUT"
