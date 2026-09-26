#!/bin/bash
BACKUP_DIR=/opt/coevo/backups/db
DB=/opt/coevo/data/coevo.db
RETENTION=7
DATE_TAG=$(date +%Y%m%d)
BACKUP_FILE="${BACKUP_DIR}/coevo.${DATE_TAG}.db"
BACKUP_GZ="${BACKUP_FILE}.gz"

LOG() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${BACKUP_DIR}/backup.log"
}

mkdir -p "$BACKUP_DIR"

if [ ! -f "$DB" ]; then
    LOG "ERROR: DB file not found: $DB"
    exit 1
fi

sqlite3 "$DB" "VACUUM INTO '${BACKUP_FILE}';" 2>>"${BACKUP_DIR}/backup.log"
if [ $? -ne 0 ] || [ ! -s "$BACKUP_FILE" ]; then
    LOG "WARN: VACUUM INTO failed, retrying with cp..."
    sleep 5
    cp "$DB" "$BACKUP_FILE" 2>>"${BACKUP_DIR}/backup.log"
fi

if [ ! -s "$BACKUP_FILE" ]; then
    LOG "ERROR: backup file is empty, aborting"
    exit 2
fi

INTEGRITY=$(sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;" 2>>"${BACKUP_DIR}/backup.log")
if [ "$INTEGRITY" != "ok" ]; then
    LOG "ERROR: backup integrity check failed: $INTEGRITY"
    rm -f "$BACKUP_FILE"
    exit 3
fi

gzip -f "$BACKUP_FILE"
if [ $? -ne 0 ] || [ ! -s "$BACKUP_GZ" ]; then
    LOG "ERROR: gzip failed"
    exit 4
fi

find "$BACKUP_DIR" -name "coevo.*.db.gz" -mtime +$RETENTION -delete

FILESIZE=$(ls -lh "$BACKUP_GZ" | awk '{print $5}')
LOG "DB backup done: coevo.${DATE_TAG}.db.gz (${FILESIZE})"
