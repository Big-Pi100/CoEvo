#!/usr/bin/env bash
# CoEvo 后端 · **更新部署**（只换二进制 · 不碰 .env / unit / 邻居服务）
#
# 与 `deploy_step1.sh` 的区别：
#   deploy_step1 = **首次部署**（建目录 + 装 unit + 放 .env + 同步 prompts）
#   本脚本       = **更新**（.env / unit / prompts 都不动，只换二进制）
#
# 🔴 为什么更新时不覆盖 .env：
#   `/opt/coevo/.env` 是**生产密钥**的唯一副本（330+ 字节，含 ADMIN_KEY / PII_KEY）。
#   首次部署脚本里有它是因为「当时还没有」；更新时若照抄那段，
#   就会用**本地那份**（可能是占位符/过期）覆盖生产 → 服务起不来或密钥变化。
#   📌 判据：**「首次」与「更新」的脚本必须分开** —— 混用会静默覆盖生产配置。
#
# 🔴 为什么更新时不无条件覆盖 prompts / cefr_catalog.json：
#   这两样本轮**没改**。无条件覆盖 = 每次部署都做一次**无意义的写**，
#   而且一旦本地那份落后（比如在旧分支上构建），就会**把生产的内容回退**。
#   → 默认不动；要更新用 `--with-assets`（且会先备份）。
#
# 前置：/tmp/coevo_stage/coevo_backend 已放好（由 `build_linux_in_wsl.sh` 产出后 scp 上来）
#
# 用法：
#   bash deploy_update.sh              # 只换二进制
#   bash deploy_update.sh --with-assets  # 同时更新 prompts + cefr_catalog.json
#
# 📄 依据：docs/design/coevo-vps-deployment-assessment-2026-09-29.md §十二（步骤 2）
# 🔴 绝不碰：vibedollar-pay(:8100) · mailproxy(:8200) · nginx(80/443) ·
#     现有证书 · `/opt/coevo/.env` · `/etc/systemd/system/coevo.service`
set -euo pipefail

STAGE=/tmp/coevo_stage
DEST=/opt/coevo
BIN=$DEST/bin/coevo_backend
WITH_ASSETS=0
[ "${1:-}" = "--with-assets" ] && WITH_ASSETS=1

echo "=== 0/7 前置检查 ==="
if [ ! -f "$STAGE/coevo_backend" ]; then
  echo "🔴 缺少 $STAGE/coevo_backend（先跑 build_linux_in_wsl.sh 并 scp 上来）"; exit 1
fi
# 🔴 先验它是 **ELF x86-64**，不是 Windows PE —— 否则部署完起不来，
#    而现象是 systemd 报 format error（看起来像权限问题，容易查错方向）
FILE_OUT=$(file -b "$STAGE/coevo_backend")
echo "  产物类型: $FILE_OUT"
case "$FILE_OUT" in
  *ELF*x86-64*) echo "  ✅ ELF x86-64" ;;
  *) echo "🔴 不是 Linux x86-64 ELF —— 是不是在 Windows 上构建的？（会产出 PE .exe）"; exit 1 ;;
esac
ls -la "$STAGE/coevo_backend"
echo "  现有版本:"; ls -la "$BIN" 2>/dev/null || echo "  （无 —— 首次？那该用 deploy_step1.sh）"

echo
echo "=== 1/7 留存回滚点（.prev）==="
if [ -f "$BIN" ]; then
  cp -a "$BIN" "$DEST/bin/coevo_backend.prev"
  echo "  ✅ 已备份 → $DEST/bin/coevo_backend.prev"
  ls -la "$DEST/bin/coevo_backend.prev"
else
  echo "  ⚠️ 没有现有二进制可备份（首次部署？）"
fi

echo
echo "=== 2/7 换二进制 ==="
install -m 755 "$STAGE/coevo_backend" "$BIN"
ls -la "$BIN"
# 🔴 显式补执行位 —— `install -m 755` 已经设了，但**跨工具传文件不要假设权限被保留**
#    （2026-10-01 踩过：artifact 丢执行位 → rsync 传播 644 → systemd 203/EXEC）
chmod 755 "$BIN"
test -x "$BIN" || { echo "🔴 二进制不可执行 —— 中止（不重启，避免打断线上）"; exit 1; }
echo "  ✅ 执行位就位"

if [ "$WITH_ASSETS" = "1" ]; then
  echo
  echo "=== 2b/7 更新 assets（--with-assets）==="
  TS=$(date +%Y%m%d%H%M)
  [ -f "$DEST/cefr_catalog.json" ] && cp -a "$DEST/cefr_catalog.json" "$DEST/cefr_catalog.json.bak-$TS"
  [ -d "$DEST/prompts" ] && cp -a "$DEST/prompts" "$DEST/prompts.bak-$TS"
  cp "$STAGE/cefr_catalog.json" "$DEST/"
  rm -rf "$DEST/prompts"; cp -r "$STAGE/prompts" "$DEST/prompts"
  echo "  ✅ assets 已更新（旧版备份为 .bak-$TS）"
else
  echo
  echo "=== 2b/7 跳过 assets（未加 --with-assets）==="
  echo "  prompts / cefr_catalog.json 保持不动 ✅"
fi

echo
echo "=== 3/7 重启服务 ==="
echo "  ⚠️ 重启会**立即触发一轮抓取**（首轮延迟 30s）—— 这是预期行为"
sudo systemctl restart coevo
sleep 5

echo
echo "=== 4/7 健康检查（最多 8 次）==="
HEALTH=000
for i in $(seq 1 8); do
  HEALTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8300/health 2>/dev/null || echo 000)
  echo "  尝试 $i: HTTP $HEALTH"
  [ "$HEALTH" = "200" ] && break
  sleep 3
done

if [ "$HEALTH" != "200" ]; then
  echo
  echo "🔴 健康检查失败 → **自动回滚**"
  if [ -f "$DEST/bin/coevo_backend.prev" ]; then
    # 把失败的版本留档（⚠️ 不覆盖 .prev —— 否则现场被销毁，事后查不出原因）
    cp -a "$BIN" "$DEST/bin/coevo_backend.failed-$(date +%Y%m%d%H%M)"
    install -m 755 "$DEST/bin/coevo_backend.prev" "$BIN"
    sudo systemctl restart coevo
    sleep 5
    echo "  回滚后健康: $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8300/health || echo 000)"
    echo "  失败版本已留档为 coevo_backend.failed-*"
  else
    echo "  ⚠️ 无 .prev 可回滚"
  fi
  echo
  echo "--- 失败原因（最近 30 行日志）---"
  sudo journalctl -u coevo -n 30 --no-pager || true
  exit 1
fi

echo
echo "=== 5/7 内存与监听 ==="
systemctl show coevo -p MemoryCurrent -p MemoryMax --value | paste - - | awk '{printf "  内存: %.1f MB / %.1f MB\n", $1/1048576, $2/1048576}'
echo "  --- 监听（应仅 127.0.0.1:8300）---"
ss -ltn 2>/dev/null | grep 8300 || echo "  🔴 未见 8300"

echo
echo "=== 6/7 🔴 复验邻居服务（必须全 active）==="
for s in vibedollar-pay mailproxy nginx; do printf "  %-18s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
echo "  --- 对外端点仍通 ---"
curl -sk -o /dev/null -w "    https://api.keyievolution.fun/health -> %{http_code}\n" --max-time 8 https://api.keyievolution.fun/health || echo "    （外网探测失败）"
curl -sk -o /dev/null -w "    https://pay.keyievolution.fun/healthz -> %{http_code}\n" --max-time 8 https://pay.keyievolution.fun/healthz || echo "    （外网探测失败）"

echo
echo "=== 7/7 抓取日志（等 45s 让首轮跑起来）==="
sleep 45
sudo journalctl -u coevo -n 50 --no-pager | grep -iE 'content_fetch|正文|新增|错误|error|panic' | tail -20 || sudo journalctl -u coevo -n 20 --no-pager

echo
echo "✅ 部署脚本结束。健康码=$HEALTH"
echo "📌 回滚命令： install -m 755 $DEST/bin/coevo_backend.prev $BIN && sudo systemctl restart coevo"
