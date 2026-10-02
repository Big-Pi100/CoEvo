#!/usr/bin/env bash
# CoEvo 后端 · VPS 部署「步骤 1」（不碰 nginx · 不新增对外暴露）
#
# 前置：/tmp/coevo_stage/ 下已放好
#   coevo_backend · cefr_catalog.json · prompts/ · .env · coevo.service
#
# 🔴 只做「新增」：
#     /opt/coevo/（bin data prompts .env）· /etc/systemd/system/coevo.service
# 🔴 绝不碰：vibedollar-pay(:8100) · mailproxy(:8200) · nginx(80/443) ·
#     现有证书 · 任何已有端口行为
# 📄 依据：docs/design/coevo-vps-deployment-assessment-2026-09-29.md §一（七条承诺）§六（步骤 1）
set -euo pipefail

STAGE=/tmp/coevo_stage
DEST=/opt/coevo

echo "=== 0/6 前置检查 ==="
for f in coevo_backend cefr_catalog.json .env coevo.service prompts; do
  if [ ! -e "$STAGE/$f" ]; then echo "🔴 缺少 $STAGE/$f"; exit 1; fi
done
echo "  上传物齐全 ✅"
if [ -f /etc/systemd/system/coevo.service ]; then
  echo "  ⚠️ 已存在旧 unit → 先备份"
  sudo cp /etc/systemd/system/coevo.service "/etc/systemd/system/coevo.service.bak-$(date +%Y%m%d%H%M)"
fi

echo
echo "=== 1/6 建目录（只新增 /opt/coevo）==="
sudo mkdir -p "$DEST/bin" "$DEST/data"
sudo chown -R ubuntu:ubuntu "$DEST"

echo
echo "=== 2/6 放置文件 ==="
install -m 755 "$STAGE/coevo_backend" "$DEST/bin/coevo_backend"
cp "$STAGE/cefr_catalog.json" "$DEST/"
rm -rf "$DEST/prompts"
cp -r "$STAGE/prompts" "$DEST/prompts"
install -m 600 "$STAGE/.env" "$DEST/.env"
echo "  --- $DEST ---"; ls -la "$DEST"
echo "  --- $DEST/bin ---"; ls -la "$DEST/bin"
echo "  --- .env 权限（必须 600）---"; stat -c '%a %n' "$DEST/.env"

echo
echo "=== 3/6 安装 systemd 单元 ==="
sudo cp "$STAGE/coevo.service" /etc/systemd/system/coevo.service
sudo systemctl daemon-reload
sudo systemctl enable coevo

echo
echo "=== 4/6 启动 ==="
sudo systemctl restart coevo
sleep 4
systemctl status coevo --no-pager | head -12 || true

echo
echo "=== 5/6 健康检查 ==="
HEALTH=000
for i in $(seq 1 8); do
  HEALTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8300/health 2>/dev/null || echo 000)
  echo "  尝试 $i: HTTP $HEALTH"
  [ "$HEALTH" = "200" ] && break
  sleep 2
done
echo "  --- 监听情况（应仅 127.0.0.1:8300）---"
ss -ltn 2>/dev/null | grep 8300 || echo "  🔴 未见 8300"

echo
echo "=== 6/6 现役服务复验（必须全 active）==="
for s in vibedollar-pay mailproxy nginx; do printf "  %-18s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done

echo
echo "=== 抓取日志（等 20s 让首轮抓取跑起来）==="
sleep 20
sudo journalctl -u coevo -n 40 --no-pager

echo
echo "✅ 部署脚本结束。健康码=$HEALTH"
