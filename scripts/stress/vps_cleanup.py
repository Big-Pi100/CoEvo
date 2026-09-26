#!/usr/bin/env python3
"""Run this on the VPS to clean up stress test users"""
import sqlite3
conn = sqlite3.connect("/opt/coevo/data/coevo.db")
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
conn.close()
print("Cleaned")
