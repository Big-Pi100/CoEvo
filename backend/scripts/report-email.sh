#!/bin/bash
# CoEvo 巡检报告邮件发送脚本
TO="<REPORT_EMAIL>"
FROM="<REPORT_EMAIL>"
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
