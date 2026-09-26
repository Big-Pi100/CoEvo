#!/usr/bin/env python3
"""Run this ON the VPS to create stress test users. No pip packages needed."""
import sqlite3
import json
import sys
import subprocess
import urllib.request
from datetime import datetime

N = int(sys.argv[1]) if len(sys.argv) > 1 else 10
DB = "/opt/coevo/data/coevo.db"

conn = sqlite3.connect(DB)

# Clean
conn.executescript("""
DELETE FROM card_memory WHERE card_id IN (SELECT id FROM cards WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%'));
DELETE FROM cards WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');
DELETE FROM learning_plans WHERE conversation_id LIKE 'chatstress%';
DELETE FROM conversation_turns WHERE conversation_id LIKE 'chatstress%';
DELETE FROM conversations WHERE id LIKE 'chatstress%';
DELETE FROM tokens WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');
DELETE FROM user_preferences WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');
DELETE FROM users WHERE username LIKE 'chatstress%';
""")
conn.commit()
print("Cleaned")

for i in range(N):
    uname = f"chatstress{i}"
    body = json.dumps({"username": uname, "password": "stress123"}).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:8080/api/auth/register",
        data=body,
        headers={"Content-Type": "application/json"}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read())
    except Exception as e:
        print(f"{i}: register failed: {e}")
        continue
    uid = data.get("user_id", "")
    if not uid:
        print(f"{i}: no user_id in {data}")
        continue
    now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    conn.execute("INSERT OR IGNORE INTO user_preferences (user_id, key, value, updated_at) VALUES (?, ?, ?, ?)",
                 (uid, "subscription_expires", "2099-12-31T23:59:59Z", now))
    conn.execute("INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?, ?, 0, ?, '语文', 'g1-2')",
                 (f"{uname}_conv", uid, now))
    print(f"{i} OK: {uid}")

conn.commit()
conn.close()
print(f"Setup complete: {N} users")
