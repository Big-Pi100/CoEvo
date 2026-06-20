-- 迁移 subscription_expires 从 user_preferences 到 users 表
-- 执行: sqlite3 data/coevo.db < scripts/migrate_subscription_expires.sql

UPDATE users SET subscription_expires = (
    SELECT value FROM user_preferences
    WHERE user_preferences.user_id = users.id
    AND key = 'subscription_expires'
)
WHERE id IN (
    SELECT user_id FROM user_preferences WHERE key = 'subscription_expires'
);
