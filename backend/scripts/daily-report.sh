#!/bin/bash
# CoEvo 每日巡检报告 - 发邮件到 <REPORT_EMAIL>
set -e
COEVO_OK=$(sudo systemctl is-active coevo 2>/dev/null || echo "inactive")
NGINX_OK=$(sudo systemctl is-active nginx 2>/dev/null || echo "inactive")
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
MEM_USED=$(free -m | grep Mem | awk '{print $3}')
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
DB_SIZE=$(ls -lh /opt/coevo/data/coevo.db | awk '{print $5}')
PLAN_COUNT=$(sudo sqlite3 /opt/coevo/data/coevo.db "SELECT COUNT(*) FROM learning_plans;")
CARD_COUNT=$(sudo sqlite3 /opt/coevo/data/coevo.db "SELECT COUNT(*) FROM cards;")
USER_COUNT=$(sudo sqlite3 /opt/coevo/data/coevo.db "SELECT COUNT(*) FROM users;")
LAST_BACKUP=$(ls -t /opt/coevo/backups/db/coevo.*.db.gz 2>/dev/null | head -1 | xargs basename 2>/dev/null | cut -d. -f2 || echo "无")
CP2_TODAY=$(grep -c 'CP2 complete' /opt/coevo/data/logs/coevo.log.$(date +%Y-%m-%d) 2>/dev/null || echo 0)
CP1_TODAY=$(grep -c 'candidates' /opt/coevo/data/logs/coevo.log.$(date +%Y-%m-%d) 2>/dev/null || echo 0)
PLANS_RECENT=$(sudo sqlite3 /opt/coevo/data/coevo.db "SELECT substr(goal,1,40) || ' | ' || substr(updated_at,1,16) FROM learning_plans ORDER BY updated_at DESC LIMIT 5;" 2>/dev/null || echo "无")

REPORT="CoEvo 每日巡检报告
时间: $(date '+%Y-%m-%d %H:%M:%S')

[服务状态]
  coevo: ${COEVO_OK}
  nginx: ${NGINX_OK}

[资源]
  磁盘: ${DISK_PCT}%
  内存: ${MEM_USED}/${MEM_TOTAL}MB (${MEM_PCT}%)

[数据]
  用户: ${USER_COUNT}
  计划: ${PLAN_COUNT}
  卡片: ${CARD_COUNT}
  DB:   ${DB_SIZE}

[备份]
  最近: ${LAST_BACKUP}

[今日活动]
  CP2 推进: ${CP2_TODAY}
  CP1 提取: ${CP1_TODAY}

[最近计划更新]
${PLANS_RECENT}"

ISSUES=""
if [ "$COEVO_OK" != "active" ]; then ISSUES="${ISSUES}  - coevo: ${COEVO_OK}\n"; fi
if [ "$NGINX_OK" != "active" ]; then ISSUES="${ISSUES}  - nginx: ${NGINX_OK}\n"; fi
if [ "$DISK_PCT" -gt 80 ]; then ISSUES="${ISSUES}  - 磁盘使用率: ${DISK_PCT}%\n"; fi

if [ -n "$ISSUES" ]; then
  REPORT="${REPORT}

[发现问题]
${ISSUES}"
fi

/opt/coevo/scripts/report-email.sh "$REPORT" "CoEvo 每日巡检 - $(date +%Y-%m-%d)"
