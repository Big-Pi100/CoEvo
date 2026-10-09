#!/usr/bin/env bash
# CoEvo · 部署包「新鲜度」自检 —— 一条**与「本批改了什么」无关**的通用判据。
#
# 用法：bash verify_artifact_fresh.sh <产物二进制> <源码目录>
# 退出码：0 = 新鲜（可以上传）· 1 = 过期（**不要上传**）· 2 = 用法/环境错误
#
# # 🔴 为什么需要它（2026-10-09 一天内踩到两次）
#
# ① 部署包的 `sha256` 与上一版**完全相同**，而它已经准备被上传 ——
#    真因是构建命令的路径少了一层，脚本**根本没跑**，
#    `%TEMP%` 里留着上一次的包（时间戳看着还挺新）。
# ② 靠「核对几个字符串字面量」判新鲜：那些字符串是**历史批次**的，
#    留着会**一直命中** ⇒ 判据退化成「这些老功能还在吗」（本节就是它的修法）。
#
# ⇒ 通用判据 = **产物必须比源码新**（mtime 不变量）。
#    它对**任何**一次构建都成立，不需要每批维护 ——
#    这正是「判据要跟**意图**走、不跟**当批内容**走」的应用。
#
# ⚠️ 边界（如实标注）：mtime 能挡住「包是旧的」，
#    **挡不住**「包是新的但内容错」（源码改了没保存 / cargo 用了别的工作区）。
#    后者只能靠**当批**的特征串 —— 见调用方 `build_linux_in_wsl.sh` 的第 ② 段。
#
# ⚠️ 用 `set -uo pipefail` 而**不是** `-e`：本脚本要靠**捕获失败**来判定，
#    中途退出会让它永远返回 0（那正是「检测器失效 ⇒ 绿灯无意义」）。
set -uo pipefail

ARTIFACT="${1:-}"
SRC="${2:-}"
if [ -z "$ARTIFACT" ] || [ -z "$SRC" ]; then
  echo "用法：$0 <产物二进制> <源码目录>" >&2
  exit 2
fi
if [ ! -f "$ARTIFACT" ]; then echo "🔴 找不到产物：$ARTIFACT" >&2; exit 2; fi
if [ ! -d "$SRC" ]; then echo "🔴 找不到源码目录：$SRC" >&2; exit 2; fi

echo "── ① 通用判据：产物是否比源码新 ──"
echo "   产物: $ARTIFACT"
_ts=$(date -r "$ARTIFACT" '+%F %T' 2>/dev/null || true)
[ -n "$_ts" ] && echo "   mtime: $_ts"

# ⚠️ 用**命令替换**收集，不接管道 —— `head` 提前退出会让上游收到 SIGPIPE，
#    在 `pipefail` 下把整条命令判成失败（同族：本项目 `grep -c` + `set -e` 那次静默中断）。
# ⚠️ 路径含空格时下面的 `for` 会拆错 —— 本仓库路径不含空格，如实标注。
_newer=$(find "$SRC" -path "$SRC/target" -prune -o \
           -type f \( -name '*.rs' -o -name 'Cargo.toml' \) \
           -newer "$ARTIFACT" -print 2>/dev/null || true)

if [ -n "$_newer" ]; then
  echo "   🔴 产物**比源码旧** —— 以下文件比它更新："
  _i=0
  for _f in $_newer; do
    echo "        · $_f"
    _i=$((_i + 1))
    [ "$_i" -ge 5 ] && break
  done
  echo "   ⇒ **构建没有真的执行过**（这是上一次留下的包）。请不要上传。"
  exit 1
fi
echo "   ✅ 产物比源码目录下所有 .rs / Cargo.toml 都新（构建确实执行过）"
exit 0
