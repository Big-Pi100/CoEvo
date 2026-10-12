#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# CoEvo 法律文本页 · 部署到生产（api.keyievolution.fun/privacy · /terms）
# ══════════════════════════════════════════════════════════════════════════
#
# 🔴 使用前提：**已获得白哥明确批准**（项目铁律：动生产必须先请示，含静态文件）。
#
# 🔴 为什么叫 `publish_` 而不是 `deploy_`（**别改名**）：
#    `.gitignore` 有一条护栏 `deploy*.sh` —— 它的意图是
#    「**防止已删除的废弃部署脚本重新出现**」（那些老脚本里曾含密钥/凭据，
#      已做过 git history purge）。本脚本撞上这个模式 ⇒ **进不了 git**。
#    ⇒ 正确修法是**本脚本改名**，而不是给护栏开例外 ——
#      开例外会在护栏上留一道裂缝，以后真需要防的脚本也可能从那儿溜进来。
#    📌 判据：**改不动的是规则，能改的是自己**（当规则有正当意图时）。
#    ⚠️ 若把它改回 `deploy_*`，`git add` 会报
#      "The following paths are ignored by one of your .gitignore files"。
#
# 用法：
#   scripts/legal/publish_legal_pages.sh \
#       --operator "张三" --email "support@example.com"
#
# 它会做（五步，每步都可独立核对）：
#   ① 生成 HTML（占位符 → 真实值）
#   ② 上传到 /var/www/coevo-legal/
#   ③ **幂等**插入 nginx location（带起止标记，重复跑不会重复插入）
#   ④ nginx -t 校验 → reload（**校验失败自动从备份恢复**）
#   ⑤ 公网验证两个 URL（HTTP 200 + 内容检查 + **无残留占位符**）
#
# 🔴 本脚本的三条安全约束（都是本项目踩过的坑）：
#
#   ① **只加不改**：`zz-coevo` 里已有的 location 一律不动。
#      共享机器上还有 `vibedollar-pay` 等邻居 ⇒ **只碰本项目的站点文件**。
#   ② **改前备份 + 校验失败回滚**：nginx 配置坏了会**连累所有站点**，
#      所以「先 `nginx -t`，通过才 reload」是必须的（不是谨慎，是底线）。
#   ③ **验证不只看状态码**：还要查内容里**没有** `【待填` ——
#      否则会把「未填完的法律文本」发布到公网（比部署失败更严重）。
#
# 退出码：0 = 成功 · 非 0 = 失败（**失败时不会留下半成品配置**）
# ══════════════════════════════════════════════════════════════════════════

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/coevo_key}"
VPS_USER="${VPS_USER:-ubuntu}"
VPS_HOST="${VPS_HOST:-<VPS_IP>}"
WEB_ROOT="/var/www/coevo-legal"
NGINX_CONF="/etc/nginx/sites-available/zz-coevo"
PUBLIC_BASE="${PUBLIC_BASE:-https://api.keyievolution.fun}"

OPERATOR=""
EMAIL=""
EFF_DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator)       OPERATOR="$2"; shift 2 ;;
    --email)          EMAIL="$2";    shift 2 ;;
    --effective-date) EFF_DATE="$2"; shift 2 ;;
    *) echo "🔴 未知参数：$1"; exit 2 ;;
  esac
done

if [[ -z "$OPERATOR" || -z "$EMAIL" ]]; then
  echo "🔴 必须提供 --operator 与 --email"
  echo "   例：$0 --operator \"张三\" --email \"support@example.com\""
  exit 2
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=20)
remote() { ssh "${SSH_OPTS[@]}" "$VPS_USER@$VPS_HOST" "$@"; }

echo "════════════════════════════════════════════════════════"
echo " CoEvo 法律文本页部署"
echo " 运营者：$OPERATOR"
echo " 邮箱：  $EMAIL"
echo " 站点：  $PUBLIC_BASE/privacy · /terms · /support"
echo "════════════════════════════════════════════════════════"
echo

# ── ① 生成 HTML ──────────────────────────────────────────────────────────
echo "▶ ① 生成 HTML"
PY="$REPO_ROOT/scripts/legal/build_legal_pages.py"

# 🔴 为什么不能直接写 `python3`：
#    Windows 上 `python3` 往往是 **Microsoft Store 的占位符** ——
#    `command -v python3` **能查到**，但一运行就弹「请到商店安装」并失败。
#    ⇒ 先找**项目自带的解释器**，找不到再退回 `python3`。
#    ⚠️ 覆盖方式：`PYBIN=/path/to/python $0 ...`
if [[ -z "${PYBIN:-}" ]]; then
  _cand="C:/Users/Lenovo/.workbuddy/binaries/python/versions/3.13.12/python.exe"
  if [[ -f "$_cand" ]]; then
    PYBIN="$_cand"
  else
    PYBIN="python3"
  fi
fi
echo "  python: $PYBIN"
# ⚠️ 不能用 `[[ -n x ]] && EXTRA+=(...)` 的简写 —— 条件为假时整个表达式返回 1，
#    在 `set -e` 下**会直接退出脚本**（经典陷阱）。用 if 才安全。
EXTRA=()
if [[ -n "$EFF_DATE" ]]; then
  EXTRA+=(--effective-date "$EFF_DATE")
  echo "  生效日期：$EFF_DATE（覆盖默认的「今天」）"
fi
"$PYBIN" "$PY" --operator "$OPERATOR" --email "$EMAIL" \
    --base-url "$PUBLIC_BASE" --out build/legal "${EXTRA[@]}"

# 本地先自查一次残留 —— **不把可能残缺的产物传上去**
for f in privacy terms support; do
  if grep -q '【待填' "$REPO_ROOT/build/legal/$f.html"; then
    echo "🔴 $f.html 仍有未替换占位符 ⇒ 中止（不上传）"
    exit 1
  fi
done
echo "  ✅ 三份产物本地自查通过（无残留占位符）"
echo

# ── ② 上传 ───────────────────────────────────────────────────────────────
echo "▶ ② 上传到 $WEB_ROOT"
remote "sudo mkdir -p $WEB_ROOT && sudo chown $VPS_USER:$VPS_USER $WEB_ROOT"
scp "${SSH_OPTS[@]}" "$REPO_ROOT"/build/legal/*.html \
    "$VPS_USER@$VPS_HOST:$WEB_ROOT/"
remote "chmod 644 $WEB_ROOT/*.html && ls -la $WEB_ROOT"
echo

# ── ③ 幂等插入 nginx location ────────────────────────────────────────────
echo "▶ ③ 配置 nginx（幂等 · 只加不改）"
remote "sudo python3 -" <<'REMOTE_PY'
import datetime, pathlib, re, sys

CONF = pathlib.Path("/etc/nginx/sites-available/zz-coevo")
ANCHOR = "    # 其余全量反代 —— 后端自己管路由（未知路径由 axum 返 404）"

BLOCK = """    # >>> coevo-legal (managed by scripts/legal/publish_legal_pages.sh) >>>
    #
    # CoEvo 法律文本（隐私政策 / 用户协议）—— 静态 HTML。
    #
    # 🔑 为什么是 nginx 直接给静态文件，而不是让后端出：
    #    · 这两页**与后端无关**（不查库、不鉴权）⇒ 走静态最省事、最稳
    #    · Apple 上架要求「可公开访问的 URL」，静态页天然满足
    #    · 与 `backend-deploy` 的 rsync 解耦（那个只同步 bin/ 与 prompts/）
    #
    # ⚠️ 用**精确匹配**（`location =`）—— 它优先级高于前缀匹配 `location /`，
    #    所以不会被下面的全量反代吃掉。
    #
    # ⚠️ 文件位置 /var/www/coevo-legal/ —— 与 vibedollar 等邻居站点无关，
    #    本项目的静态资源自成一处。
    location = /privacy {
        root /var/www/coevo-legal;
        try_files /privacy.html =404;
        add_header Cache-Control "public, max-age=3600";
    }
    location = /terms {
        root /var/www/coevo-legal;
        try_files /terms.html =404;
        add_header Cache-Control "public, max-age=3600";
    }
    # 🆕 2026-10-12 /support —— Apple 上架必填的「**技术支持网址**」。
    location = /support {
        root /var/www/coevo-legal;
        try_files /support.html =404;
        add_header Cache-Control "public, max-age=3600";
    }
    # <<< coevo-legal <<<
"""

src = CONF.read_text(encoding="utf-8")

# 备份（时间戳）—— 出事能回滚
ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
bak = CONF.with_suffix(CONF.suffix + f".bak-legal-{ts}")
bak.write_text(src, encoding="utf-8")
print(f"  备份: {bak}")

# 🔴 幂等：先删掉可能已存在的旧块
#
# ⚠️ 正则末尾的 `\n\n?` **不是可有可无的**（2026-10-04 实测踩到）：
#    插入时写的是 `BLOCK + "\n" + ANCHOR`（块后**多一个空行**），
#    而删除时若只吃掉块本身（不含那个空行）⇒ **删的比插的少一个 `\n`**
#    ⇒ 每跑一次就多一个空行。后果不严重（nginx 容忍空行），
#    但「**声称幂等却没验证**」本身是问题 —— 它会让后来的维护者
#    在「重复部署是否安全」这件事上**基于错误前提**做判断。
#    📌 判据：**幂等性必须被实测**（见下方自检），不能只靠读代码推断。
#    🔑 修法：让「删掉的字符」与「插入的字符」**守恒** —— 删除时同样吃掉块后的空行。
DELETE_RE = r"[ \t]*# >>> coevo-legal .*?# <<< coevo-legal <<<\n\n?"

cleaned, n = re.subn(DELETE_RE, "", src, flags=re.DOTALL)
if n:
    print(f"  （移除已有的 legal 块 ×{n}）")

if ANCHOR not in cleaned:
    print("🔴 未找到插入锚点 —— 配置结构与预期不符，**不做任何修改**")
    print(f"   期望锚点: {ANCHOR}")
    sys.exit(1)

new = cleaned.replace(ANCHOR, BLOCK + "\n" + ANCHOR, 1)

# 🔴 幂等自检：**在写出之前**模拟「再跑一次」，结果必须与本次完全一致。
#
# 为什么值得加这一步（而不只是修掉那个正则）：
#   本次的 bug 就是「幂等声明与实现不符」，而**部署脚本一年可能只跑几次**，
#   没有自检的话，同类偏差会**静默累积**（多几个空行没人发现）。
#   ⇒ 把「幂等」从**声明**变成**每次部署都跑一次的断言**。
# ⚠️ 失败则**中止且不写文件**（保持现场，便于排查）。
rebuilt = re.subn(DELETE_RE, "", new, flags=re.DOTALL)[0].replace(
    ANCHOR, BLOCK + "\n" + ANCHOR, 1
)
if rebuilt != new:
    print("🔴 幂等自检失败：模拟再跑一次的结果与本次不一致")
    print("   ⇒ **不写入**（避免每次部署累积漂移），请修 DELETE_RE / BLOCK 的边界")
    sys.exit(1)
print("  ✅ 幂等自检通过（模拟再跑一次 = 本次结果）")

CONF.write_text(new, encoding="utf-8")
print("  ✅ 已插入 legal 块")
REMOTE_PY
echo

# ── ④ nginx -t → reload（失败即回滚）─────────────────────────────────────
echo "▶ ④ 校验并 reload nginx"
if remote "sudo nginx -t"; then
  remote "sudo systemctl reload nginx"
  echo "  ✅ nginx 已 reload"
else
  echo "🔴 nginx -t 失败 ⇒ 回滚配置"
  remote "sudo cp -a \$(ls -t /etc/nginx/sites-available/zz-coevo.bak-legal-* | head -1) $NGINX_CONF && sudo nginx -t"
  echo "  ✅ 已回滚（线上未受影响）"
  exit 1
fi
echo

# ── ⑤ 公网验证 ───────────────────────────────────────────────────────────
echo "▶ ⑤ 公网验证"
FAIL=0
for path in privacy terms; do
  url="$PUBLIC_BASE/$path"
  code=$(curl -sS -o /tmp/legal_$path.html -w "%{http_code}" --max-time 20 "$url" || echo 000)
  size=$(wc -c < /tmp/legal_$path.html 2>/dev/null | tr -d ' ' || echo 0)
  printf "  %-42s HTTP %s  (%s 字节)\n" "$url" "$code" "$size"

  if [[ "$code" != "200" ]]; then
    echo "    🔴 非 200"
    FAIL=1
    continue
  fi
  # 🔴 最关键的检查：**不得**把未填完的文本发布出去
  if grep -q '【待填' /tmp/legal_$path.html; then
    echo "    🔴 页面含未替换的占位符 ⇒ 与本地产物不一致"
    FAIL=1
  fi
done

# 内容抽查：能读到正文关键串（防止「200 但是空页/错误页」）
grep -q '隐私政策' /tmp/legal_privacy.html || { echo "  🔴 privacy 页面内容异常"; FAIL=1; }
grep -q '用户协议' /tmp/legal_terms.html   || { echo "  🔴 terms 页面内容异常"; FAIL=1; }

# 顺带确认**邻居站点**仍然正常（共享机器，只加不改）
echo
echo "  邻居服务状态："
remote "for s in coevo vibedollar-pay mailproxy nginx; do printf '    %-16s %s\n' \$s \$(systemctl is-active \$s 2>/dev/null); done"

echo
if [[ "$FAIL" == "0" ]]; then
  echo "════════════════════════════════════════════════════════"
  echo " ✅ 部署完成"
  echo "    $PUBLIC_BASE/privacy"
  echo "    $PUBLIC_BASE/terms"
  echo
  echo " 📌 下一步：把这两个 URL 填进 app/lib/services/iap_plan.dart 的"
  echo "    kPrivacyPolicyUrl / kTermsOfServiceUrl（订阅页与「我的」页会用）"
  echo "════════════════════════════════════════════════════════"
else
  echo "🔴 有检查未通过（见上）"
  exit 1
fi
