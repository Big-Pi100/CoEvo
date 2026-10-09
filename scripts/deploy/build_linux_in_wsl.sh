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

# ── 5/5 自检（防「传了旧二进制」）─────────────────────────────────────
#
# 🔴 判据分**两段**，作用完全不同（2026-10-09 修正）：
#
# | 段 | 判据 | 性质 |
# |---|---|---|
# | ① | **产物必须比源码新**（mtime 不变量）| ✅ **通用** —— 对任何一次构建都成立，无需每批维护 |
# | ② | 几个**字符串字面量**仍在 | 🟠 **常驻功能标记** —— 它证明的是「这些老功能还在」，**不是**「这是本批的包」|
#
# # 🔴 为什么第 ① 段才是关键（一天内踩到两次）
#
# 真踩到的一次：部署包的 `sha256` 与上一版**完全相同**，而它已经准备被上传 ——
# 真因是构建命令的路径少了一层，脚本**根本没跑**，`%TEMP%` 里留着上一次的包。
# 而**第 ② 段当时照样全绿** —— 因为那些字符串是**历史批次**的，会一直命中。
# 📌 判据：**「每次都要手工换进来的特征串」= 迟早忘** ⇒ 必须有一条**不依赖当批内容**的判据。
#
# ⚠️ 第 ② 段的取舍（如实标注）：特征串**不要用函数名**（第 3 步 `strip` 会把符号表删掉），
#    只用**字符串字面量**；且**别再往里堆** —— 它只该放「常驻且绝不能丢」的东西，
#    堆多了又变成一份没人维护的清单。
echo
echo "=== 5/5 自检（① 新鲜度 ② 常驻功能标记）==="
_bad=0

# ── ① 通用判据（独立脚本，Windows 侧与服务器侧都能单独调用）──
#    ⚠️ 用 `tr -d '\r' | bash -s --` 而不是直接 `bash 文件`：本脚本正是被这样调用的，
#       不保证子脚本在被读到时就已去掉 CR（`bash: $'\r': command not found` 那种）。
_fresh_sh="$REPO/scripts/deploy/verify_artifact_fresh.sh"
if tr -d '\r' < "$_fresh_sh" | bash -s -- "$OUT/coevo_backend" "$REPO/backend"; then
  :
else
  echo "   🔴 新鲜度自检未通过（见上）"
  _bad=1
fi

# ── ② 常驻功能标记（证明「这些功能还在」；**不能**当成本批的依据）──
echo "── ② 常驻功能标记（这些字符串应在每次构建都命中）──"
_chk() { # $1=二进制 $2=特征串 $3=说明
  _n=$(grep -ac "$2" "$1" || true)
  if [ "$_n" -ge 1 ]; then
    printf '  ✅ %s（命中 %s）\n' "$3" "$_n"
  else
    printf '  🔴 %s —— 未命中：功能被回退了，或产物不是本次构建的\n' "$3"
    _bad=1
  fi
}
_chk "$OUT/coevo_backend" "api/auth/register" "阳性对照（证明检测器本身有效）"
_chk "$OUT/coevo_backend" "sync_highlight"    "划线同步表（2026-10-09 起的常驻结构）"
_chk "$OUT/coevo_backend" "blob_purged_users" "云端备份清理任务（常驻）"
_chk "$OUT/coevo_backend" "trial_hard_purged" "过期试用账号清理（常驻维护任务）"

if [ "$_bad" -ne 0 ]; then
  echo
  echo "🔴 自检未通过 —— **请不要上传这个包**：先确认源码已保存，再重跑本脚本。"
  exit 1
fi
echo "  ↑ ① 已证明「构建确实执行过」· ② 已证明「常驻功能都还在」⇒ 可以上传"
