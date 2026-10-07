#!/bin/bash
# CoEvo 巡检报告邮件发送脚本
#
# 🔴 2026-10-07 核实：**本脚本当前无任何调用方** ——
#    服务器上无 crontab / 无 systemd timer 调用它 · `/opt/coevo/backups/email.log` 不存在 ·
#    仓库内也零引用；且它依赖的 `/home/ubuntu/.msmtprc` 在服务器上**不存在**
#    ⇒ **一跑就会在第 11 行 `exit 1`**。
#    📌 所以「要不要配下面的邮箱」= 取决于**你将来是否启用它**；现在不配也不影响任何东西。
#
# 🔴 2026-10-07：原为**硬编码邮箱**（收件人 + 发件人）—— 属个人联系信息，
#    「仓库改公开」后会暴露 ⇒ 改为**从环境变量读**，并保留**服务器本地文件**回退。
#
# 📌 若要启用，服务器上二选一（文件方式更省事，且不会进 git）：
#      echo 'your@mail.com' | sudo tee /opt/coevo/.report-email-to   >/dev/null
#      echo 'your@mail.com' | sudo tee /opt/coevo/.report-email-from >/dev/null
#    或 export COEVO_REPORT_EMAIL_TO / COEVO_REPORT_EMAIL_FROM
#
# ⚠️ 两者都缺 ⇒ **显式报错退出**（不要静默用错地址发出去）。
TO="${COEVO_REPORT_EMAIL_TO:-}"
FROM="${COEVO_REPORT_EMAIL_FROM:-}"
[ -z "$TO" ] && [ -f /opt/coevo/.report-email-to ] && TO="$(cat /opt/coevo/.report-email-to)"
[ -z "$FROM" ] && [ -f /opt/coevo/.report-email-from ] && FROM="$(cat /opt/coevo/.report-email-from)"
if [ -z "$TO" ] || [ -z "$FROM" ]; then
  echo "ERROR: 未配置收/发件邮箱 —— 请设置 COEVO_REPORT_EMAIL_TO/FROM，"
  echo "       或创建 /opt/coevo/.report-email-to 与 /opt/coevo/.report-email-from"
  exit 1
fi
BODY="$1"
SUBJECT="${2:-CoEvo 巡检报告}"
if [ -z "$BODY" ]; then
  echo "Usage: $0 <body> [subject]"
  exit 1
fi
if [ ! -f /home/ubuntu/.msmtprc ]; then
  echo "ERROR: /home/ubuntu/.msmtprc not found"
  exit 1
fi
printf 'From: 刻意进化 CoEvo <%s>\nTo: %s\nSubject: %s\n\n%s\n' "$FROM" "$TO" "$SUBJECT" "$BODY" | msmtp -a default "$TO" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "[$(date)] Email sent: $SUBJECT" >> /opt/coevo/backups/email.log
else
  echo "[$(date)] FAILED: $SUBJECT" >> /opt/coevo/backups/email.log
fi
