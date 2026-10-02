//! 统一数据库 Schema — 生产与测试共用同一份定义
//!
//! 包含核心表 + 管理端表，所有 CREATE/ALTER/INDEX 均通过 `init_database()` 一次性执行。

/// 核心数据表（用户、对话、卡片、复习、计划等）
pub const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT DEFAULT NULL,
    -- 🆕 2026-09-29：注册标识改为**邮箱**（白哥定）。
    --
    -- 🔴 删掉的 5 列：`real_name` / `phone` / `phone_hash` / `id_number` / `bind_hash`
    --    —— 它们是微信时代的「实名 + 手机号」遗留。产品已定**不做 K12**、
    --    且 `ui-ux-refactor-assessment-2026-09-25` §4.2 原文就写着「删实名 / K12 / 分销」。
    --
    -- ⚠️ **这里改了对「已存在的库」无效** —— `CREATE TABLE IF NOT EXISTS` 见到表就跳过，
    --    不会改结构。老库（含生产库）必须靠 `run_migrations_inner` 的删列迁移。
    --    📄 那个函数里记了「为什么用条件删列而不是吞 `no such column`」。
    email TEXT DEFAULT NULL,
    deleted_at TEXT DEFAULT NULL,
    subscription_expires TEXT DEFAULT NULL,
    referral_code TEXT UNIQUE,
    referred_by TEXT REFERENCES users(id),
    referred_campaign_id TEXT REFERENCES marketing_campaigns(id),
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
-- 🔴 2026-09-29 已退役：`conversations` / `conversation_turns`（对话链）·
--    `card_memory` / `review_log`（后端 FSRS 复习状态）· `achievements`（成就改为端侧计算）
-- ── 已移除：K12 课程体系（2026-09-28 白哥决定 · 整体清退）──
-- 🔴 `user_plan_progress` / `prebuilt_plans` / `prebuilt_stages` / `prebuilt_tasks` / `plan_runs`
--    的建表语句**必须一并移除** —— 否则全新库初始化时会把**空表建回来**。
--    （`init_database` 由 `main.rs` 的守卫触发。🔴 该守卫**已于 2026-09-29 改**：
--      原查 `users`/`user_cards`/`card_memory` —— 后两者随旧学习链退役后守卫会**恒成立**
--      → 每次启动都跑 init。现改查 `users`/`tokens`/`payment_orders`（现役业务表）。）
-- 🔑 判据：**「删掉数据」与「让它不再产生」是两件事** —— 只 DROP TABLE 是治标。
-- 📄 决策与执行记录 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

-- ── 已移除：词卡内容表（`prebuilt_cards` + 4 张域子表）──
-- 🔴 理由（2026-09-28 白哥决定）：**维护两份词库既无意义又易互相污染**。
--    端侧词库已完全独立（app 只读 `assets/word.db`），后端的词卡接口
--    （`/api/cards/*`）**已无现役消费者**（只被死代码 `chat_client` → `pipelines`(K12) 调）。
-- 🔴 **必须与 `user_cards` 的外键一并去掉** —— 实测：`user_cards` 有 4,998 行引用
--    `prebuilt_cards`，直接 `DROP TABLE prebuilt_cards` 会报 `FOREIGN KEY constraint failed`
--    （后端启用 `PRAGMA foreign_keys = ON`，见 `db_pool.rs:29`）。
--    数据层已通过重建 `user_cards` 去掉该外键（见 `scripts/purge_coevo_wordcards.py`）。
-- 🔄 后续（2026-09-29）：`user_cards` **整表已退役**（学习状态迁端侧 `user.db`），
--    故上条「列保留」已不再适用 —— 见下方「已退役：user_cards 一族」。
-- 📄 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

-- 🔴 2026-09-29 已退役：`user_cards` / `user_{science,language,literature,humanities}_cards` /
--    `card_relations` —— 学习状态已整体迁到端侧 `user.db`（`card_review_state` 等）
CREATE TABLE IF NOT EXISTS trial_ip_log (
    id TEXT PRIMARY KEY,
    ip TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_trial_ip_log_ip_created ON trial_ip_log(ip, created_at);
"#;

/// 分销营销表（依赖 admin_users、payment_orders 等管理端表，需要在 ADMIN_SCHEMA_SQL 之后执行）
pub const DISTRIBUTION_SCHEMA_SQL: &str = r#"
-- ── Distribution & Marketing Tables ──
CREATE TABLE IF NOT EXISTS marketing_campaigns (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    campaign_type TEXT DEFAULT 'standard',
    description TEXT,
    status TEXT DEFAULT 'draft',
    rewards TEXT NOT NULL DEFAULT '[]',
    trigger_event TEXT NOT NULL DEFAULT 'registration',
    target_roles TEXT DEFAULT '[]',
    push_trigger TEXT DEFAULT 'manual',
    push_cron TEXT,
    attribution_window INTEGER DEFAULT 30,
    valid_from TEXT,
    valid_until TEXT,
    participant_limit INTEGER,
    per_user_limit INTEGER,
    qr_code_url TEXT,
    created_by TEXT,                          -- "super"（管理密钥）或 admin_users.id
    created_at TEXT NOT NULL,
    updated_by TEXT,                          -- 最后修改者
    updated_at TEXT,
    poster_prompt TEXT,                        -- 自定义海报系统提示（主prompt）
    poster_template TEXT,                      -- LLM 生成的海报 SVG 模板（含 {变量}）
    h5_template TEXT,                          -- LLM 生成的 H5 HTML 模板（含 {变量}）
    h5_prompt TEXT,                            -- 自定义 H5 系统提示
    display_positions TEXT DEFAULT '[]',       -- 展示方式：notification（通知中心）/ popup（弹窗）/ both（两者），默认空='both'
    min_member_count INTEGER DEFAULT 1,        -- party=all 时的最小成团人数，默认 1 人人即发
    FOREIGN KEY (created_by) REFERENCES admin_users(id),
    FOREIGN KEY (updated_by) REFERENCES admin_users(id)
);
CREATE TABLE IF NOT EXISTS referral_clicks (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    referrer_id TEXT NOT NULL,
    clicker_anonymous_id TEXT,
    share_channel TEXT,
    landed_page TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (referrer_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_clicks_campaign ON referral_clicks(campaign_id);
CREATE INDEX IF NOT EXISTS idx_clicks_referrer ON referral_clicks(referrer_id);
CREATE INDEX IF NOT EXISTS idx_clicks_anonymous ON referral_clicks(clicker_anonymous_id);
-- 佣金表（只 INSERT 不修改，所有资金操作通过 distribution_expenses 追溯）
CREATE TABLE IF NOT EXISTS distribution_commissions (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    earner_id TEXT NOT NULL,
    buyer_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    order_amount INTEGER NOT NULL,
    rate_applied REAL NOT NULL,
    amount INTEGER NOT NULL,
    level INTEGER DEFAULT 1,
    status TEXT DEFAULT 'locked',
    batch_id TEXT,
    batch_settled_at TEXT,
    paid_at TEXT,
    unlocked_at TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (buyer_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id)
);
CREATE INDEX IF NOT EXISTS idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX IF NOT EXISTS idx_commission_batch ON distribution_commissions(batch_id);
-- 支出记录表（所有资金操作只 INSERT，永不修改原始佣金记录）
-- expense_type: 'subscription' | 'withdrawal'
-- status:
--   subscription: pending → confirmed
--   withdrawal:   pending → confirmed(已审批) → paid(已打款)
CREATE TABLE IF NOT EXISTS distribution_expenses (
    id TEXT PRIMARY KEY,
    earner_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    expense_type TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    fee INTEGER DEFAULT 0,
    actual_amount INTEGER,
    ref_commission_id TEXT,
    handled_by TEXT,
    handled_at TEXT,
    batch_no TEXT,
    batch_paid_at TEXT,
    note TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (earner_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_expenses_earner ON distribution_expenses(earner_id, status);
CREATE INDEX IF NOT EXISTS idx_expenses_batch_no ON distribution_expenses(batch_no);

-- 用户净可用余额视图（统一公式，避免多处重复 SQL）
CREATE VIEW IF NOT EXISTS v_user_available_balance AS
SELECT dc.earner_id,
       COALESCE(SUM(dc.amount), 0)
       - COALESCE((
           SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses
           WHERE earner_id = dc.earner_id AND expense_type = 'withdrawal' AND status NOT IN ('cancelled')
       ), 0)
       - COALESCE((
           SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses
           WHERE ref_commission_id IN (
               SELECT id FROM distribution_commissions
               WHERE earner_id = dc.earner_id AND status = 'available'
           ) AND expense_type = 'subscription' AND status = 'confirmed'
       ), 0) AS available_balance
FROM distribution_commissions dc
WHERE dc.status = 'available'
GROUP BY dc.earner_id;

CREATE TABLE IF NOT EXISTS user_notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    notification_type TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    read INTEGER DEFAULT 0,
    action_url TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON user_notifications(user_id, read, created_at);
CREATE TABLE IF NOT EXISTS reward_fulfillments (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    referral_click_id TEXT,
    order_id TEXT,
    user_id TEXT NOT NULL,
    party TEXT NOT NULL,
    reward_type TEXT NOT NULL,
    reward_value TEXT NOT NULL,
    trigger_event TEXT NOT NULL,
    level INTEGER DEFAULT 1,
    status TEXT DEFAULT 'pending',
    fulfilled_at TEXT,
    error_msg TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id),
    FOREIGN KEY (referral_click_id) REFERENCES referral_clicks(id)
);
CREATE INDEX IF NOT EXISTS idx_fulfillment_campaign ON reward_fulfillments(campaign_id, trigger_event);
CREATE INDEX IF NOT EXISTS idx_fulfillment_conversion ON reward_fulfillments(referral_click_id);
CREATE INDEX IF NOT EXISTS idx_fulfillment_order ON reward_fulfillments(order_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_fulfillment_unique ON reward_fulfillments(campaign_id, user_id, trigger_event, party, reward_type, order_id);
-- ── 拼团/砍价活动成员表 ──
CREATE TABLE IF NOT EXISTS campaign_members (
    campaign_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    role TEXT DEFAULT 'member',
    created_at TEXT NOT NULL,
    PRIMARY KEY (campaign_id, user_id),
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_campaign_members_campaign ON campaign_members(campaign_id);
CREATE INDEX IF NOT EXISTS idx_campaign_members_user ON campaign_members(user_id);
"#;

/// 管理端表（管理员、订阅审计、监护人等）
pub const ADMIN_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending',
    status TEXT NOT NULL DEFAULT 'pending',
    real_name TEXT,
    phone TEXT,
    id_number TEXT,
    guardian_declaration TEXT,
    apply_reason TEXT,
    reject_reason TEXT,
    registered_from TEXT,
    created_by TEXT,
    created_at TEXT NOT NULL,
    approved_at TEXT
);
CREATE TABLE IF NOT EXISTS subscription_requests (
    id TEXT PRIMARY KEY,
    target_user_id TEXT NOT NULL,
    requested_by TEXT NOT NULL,
    reviewed_by TEXT,
    package TEXT NOT NULL,
    channel TEXT,
    note TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    reject_reason TEXT,
    requested_at TEXT NOT NULL,
    reviewed_at TEXT,
    FOREIGN KEY (target_user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);
-- ── 已移除：`guardian_assignments`（家长-学生绑定 · K12 遗留）──
-- 随 K12 体系一并清退（2026-09-28）。索引 `idx_guardian_assignments_*` 同删。
-- 📄 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at);
ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}';

-- 订阅套餐表
CREATE TABLE IF NOT EXISTS subscription_plans (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    duration_days INTEGER,
    price INTEGER NOT NULL,
    max_uses INTEGER,
    used_count INTEGER DEFAULT 0,
    once_per_user INTEGER DEFAULT 0,
    available_from TEXT,
    available_until TEXT,
    sort_order INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1,
    created_at TEXT NOT NULL
);

-- 支付订单表
CREATE TABLE IF NOT EXISTS payment_orders (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    currency TEXT DEFAULT 'CNY',
    status TEXT DEFAULT 'NOTPAY',
    prepay_id TEXT,
    transaction_id TEXT,
    paid_at TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status);

-- 订阅操作审计表
CREATE TABLE IF NOT EXISTS subscription_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    operator_id TEXT,
    target_user_id TEXT NOT NULL,
    old_expires TEXT,
    new_expires TEXT NOT NULL,
    amount INTEGER DEFAULT 0,
    order_id TEXT,
    note TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON subscription_audit_log(created_at);

-- 初始化套餐数据（三档默认定价，其他特殊定价走营销活动）
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('30d', '月度会员', 30, 12000, 0, 1, datetime('now'));
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('90d', '季度会员', 90, 35000, 1, 1, datetime('now'));
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('365d', '年度会员', 365, 128000, 2, 1, datetime('now'));

-- 运行时配置表
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT DEFAULT '',
    updated_at INTEGER NOT NULL
);

-- 🔴 2026-09-29 已退役：`debug_trackers` / `debug_logs`（只服务 admin 调试面板）
"#;

/// 用户偏好表（部分测试创建，统一放在此处）
pub const USER_PREFERENCES_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id TEXT NOT NULL, key TEXT NOT NULL,
    value TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

/// 词库在线制卡缓存 —— LLM 兜底的「服务端全局缓存」
///
/// # 为什么是「服务端全局」层
///
/// 三层缓存里的**主力层**（`docs/design/llm-card-online-path-2026-09-29.md` §十一）：
/// · 端侧缓存 → 只管**本机**重复查
/// · **本层**   → **跨用户**复用 ⇒ 成本 **∝ 唯一词数**（**不 ∝ 用户数**）← 「趋近于 0」的关键
/// · `word.db` → 离线可用，靠**版本发布**固化
///
/// # 出处（L0 原文，非新设计）
///
/// · `v1-final-design-authoritative-2026-09-25.md` **第 479 行**：`generated_card_cache`（`spelling` PK · `hit_count`）
/// · `on-demand-generation-server-side-2026-09-26.md` §4.2 / §4.3（竞态）
///
/// # 字段说明
///
/// | 字段 | 为什么 |
/// |---|---|
/// | `spelling` | **PK + `COLLATE NOCASE`** → 🔑 **去重靠 PK**（不靠 `hit_count`）· 大小写归一 |
/// | `card_content` | 卡片 JSON —— **与 `word.db` 的 `card.content` 同构** → 回流时可复用同一套落库链 |
/// | `contract_version` | 🔴 生成时的契约版本 → **契约升级后可识别/失效陈旧缓存**（否则旧 prompt 产物永远留着） |
/// | `source` | L0 已有 → 区分来源，**回流进 `word.db` 后仍能追溯** |
/// | `hit_count` | L0 设计 → 只管**回流门槛**（不代表去重） |
/// | `distinct_user_count` | 🆕 更真实的**需求信号**（避免同一人反复查把门槛刷过去） |
/// | `created_at` / `updated_at` | 审计 |
///
/// ⚠️ `distinct_user_count` 的**前提**：请求要带一个**匿名设备标识**（端侧生成、不涉及登录）——
///    因为产品原则是「**除生词表上限外不验证登录态**」。没有该标识时**不减分**：只不加。
pub const WORDLIB_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS generated_card_cache (
    spelling            TEXT PRIMARY KEY COLLATE NOCASE,
    card_content        TEXT NOT NULL,
    contract_version    TEXT NOT NULL,
    source              TEXT NOT NULL DEFAULT 'llm-online',
    hit_count           INTEGER NOT NULL DEFAULT 0,
    distinct_user_count INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gcc_hits ON generated_card_cache (hit_count DESC);

-- 「谁查过这个词」—— 只为算 `distinct_user_count`（回流门槛的真信号）
--
-- 🔑 为什么单独一张表：`hit_count` 会被同一人反复查刷高，
--    而回流门槛要的是「**有多少个不同的人**真的需要它」。
--    PK(spelling, device_id) → **天然去重**（同一设备反复查只算一次）。
--
-- ⚠️ `device_id` 是**匿名设备标识**（端侧生成，不涉及登录）——
--    产品原则是「除生词表上限外不验证登录态」。请求没带时不写本表（只 +hit_count）。
CREATE TABLE IF NOT EXISTS generated_card_hit (
    spelling    TEXT NOT NULL COLLATE NOCASE,
    device_id   TEXT NOT NULL,
    first_hit_at TEXT NOT NULL,
    hit_count   INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (spelling, device_id)
);
"#;

/// 内容源 + 内容池（**服务端共享**）—— 信息流的数据源
///
/// 依据：`docs/design/content-source-strategy-evaluation-2026-09-25.md` §四
///      （架构 = **共享内容池**，不是按用户抓取）
///
/// # 🔴 为什么必须是「服务端共享池」
/// 若按「每用户按兴趣单独抓取」：成本 ∝ **用户数 × 抓取频率** → 边际成本线性增长。
/// 共享池则是「每日固定次数抓取 → 全用户共用」→ 成本 ∝ **源数量**（与用户数无关）。
/// 方案实测核算：100 个源 · 每 6 小时 → **¥0.18/月**。
///
/// # 🔴 只建这两张表（**方案 §4.3 的另外两张有意不建**）
/// | 方案里的表 | 处置 | 理由 |
/// |---|---|---|
/// | `content_source` | ✅ 建 | 源配置 |
/// | `content_pool` | ✅ 建 | 内容池本体 |
/// | `user_read` | 🔴 **不建** | 与端侧 `user.db.article_read` **重复**。「**学习状态已整体迁端侧**」（2026-09-29 定）→ 再建一张服务端阅读表就是**同一个口径两个出处**，必然漂移。端侧的 `article_read(article_id PK)` 已是权威。 |
/// | `user_interest` | 🔴 **不建** | ① 兴趣偏好属**端侧 prefs**（同「主题」的处置）② 且「兴趣怎么影响信息流排序」**尚未设计**（方案自己标注）→ 现在建表是**没有依据的结构**。 |
/// → 🔑 判据：**「方案里写了」≠「现在就该建」** —— 方案是 09-25 写的，
///    而「学习状态迁端侧」是 09-29 定的后手决策，**新决策覆盖旧方案**。
///
/// # 🔴 时间列一律 **UTC ISO8601 带 `Z`**（不用 `datetime('now')`）
/// 本库其它表用过 `datetime('now')`（它产出「空格分隔、无 `Z`」）。
/// 但本表的时间**要下发给 App**，而 Dart 的 `DateTime.parse` 对无时区标记的串
/// **静默按本地时区解释** → 跨时区错位（端侧 `user.db` 正是为此刻了同一条硬约束）。
/// → 本表统一 `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`，与端侧对齐。
///
/// # 🔑 `content_pool.id` 用 `AUTOINCREMENT`（**不是**普通 `INTEGER PRIMARY KEY`）
/// 端侧 `article_read.article_id` 是 **INTEGER**，指向的正是本表的 `id`。
/// 普通 `INTEGER PRIMARY KEY` 在**删除后会复用** id（取 max+1）——
/// 若内容池做保留期清理，被清理文章的 id 会被新文章占用
/// → 端侧那条「已读」记录会**静默指向另一篇文章**。
/// `AUTOINCREMENT` 保证 id 单调不复用 → 断掉这条静默错配。
pub const CONTENT_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS content_source (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    name               TEXT    NOT NULL,
    url                TEXT    NOT NULL,
    kind               TEXT    NOT NULL DEFAULT 'rss',   -- rss | hn
    category           TEXT,                             -- news | tech | science | culture | business | life
    cefr_hint          TEXT,                             -- A2 | B1 | B2 | C1（难度提示）
    license            TEXT,                             -- public_domain | cc | news | esl
    -- 1 = 允许**全文**入库并展示；0 = 只存摘要 + 链接（Flipboard 模式）
    -- ⚠️ 新闻类取 1 是白哥 2026-09-29 的选择（方案原建议 0）→ 风险等级见方案文档
    redistributable    INTEGER NOT NULL DEFAULT 0 CHECK (redistributable IN (0, 1)),
    -- 🔴 **源的时间戳不带时区时，按哪个偏移解释**（分钟；东八区 = 480）
    --
    -- 为什么必须有这一列（2026-09-29 冒烟实测）：
    --   实测 4 个 RSS 源里 **3 个是 RFC 2822**（`Tue, 29 Sep 2026 07:36:24 -0400`，自带时区）；
    --   而 **ECNS 是 `2026-09-29 21:34:24`** —— 非标准格式**且没有时区标记**。
    --   🔴 此时**不能猜 UTC**：按 UTC 解释那条会变成 `21:34Z`，
    --      比抓取时刻（`15:58Z`）**还晚** → 未来时间。它实际是**北京时间**。
    --   → 时区是**每个源的属性**（源站的本地惯例），所以做成**配置**而不是写死在解析器里。
    --   ⚠️ 带时区的格式（RFC 2822）**不受本列影响** —— 它自带偏移，以它为准。
    tz_offset_min      INTEGER NOT NULL DEFAULT 0,
    fetch_interval_min INTEGER NOT NULL DEFAULT 360,
    enabled            INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    last_fetch_at      TEXT,
    fail_count         INTEGER NOT NULL DEFAULT 0,
    created_at         TEXT    NOT NULL,
    updated_at         TEXT    NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_csrc_url ON content_source (url);
CREATE INDEX IF NOT EXISTS idx_csrc_due ON content_source (enabled, last_fetch_at);

CREATE TABLE IF NOT EXISTS content_pool (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- = 端侧的 article_id（见上方说明）
    source_id    INTEGER REFERENCES content_source(id),
    title        TEXT    NOT NULL,
    summary      TEXT,                                -- 摘要（RSS description）
    body         TEXT,                                -- 全文（仅 redistributable=1 的源）
    url          TEXT    NOT NULL,
    author       TEXT,                                -- dc:creator（⚠️ 不放 service 层做展示决策）
    category     TEXT,
    published_at TEXT,                                -- UTC ISO8601 带 Z（源给的 RFC822 要归一）
    fetched_at   TEXT    NOT NULL,                    -- UTC ISO8601 带 Z
    word_count   INTEGER,                             -- 生词密度参考
    score        INTEGER,                             -- 热帖分数（HN · 供「热帖」排序）
    comments     INTEGER,                             -- 热帖评论数（HN）
    -- 🆕 抓正文的**尝试记录**（UTC ISO8601 带 `Z`）
    --
    -- # 🔴 为什么需要这一列（不是「以后可能有用」）
    -- 补抓正文的查询是「挑缺 body 的去抓」。若**不记录尝试**：
    -- · 抓失败（网络/页面结构变了/对方防爬）的条目**每轮都被重新挑中**
    -- · 每轮都白发一次请求，且**永远占着配额** → 真正需要抓的被挤掉
    -- → 记录「试过了」= 天然只试一次。
    --
    -- ⚠️ **成功也要写**（不只是失败）：不然「成功但正文为空」的条目同样会被反复挑中。
    -- 🔑 判据：**任何「按缺失挑候选」的批处理，都要有「试过」的记录** ——
    --    否则失败项会变成永久噪音。同族：`content_source.fail_count` 也是这个道理。
    body_attempted_at TEXT,
    UNIQUE (url)                                      -- 🔑 幂等键：同一 URL 只入库一次
);
CREATE INDEX IF NOT EXISTS idx_cpool_cat_time ON content_pool (category, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_cpool_pub      ON content_pool (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_cpool_score    ON content_pool (score DESC);

-- 种子源（实测**可达**才进这份清单 —— 2026-09-29 本机 + VPS 双实测）
-- 🔴 曾经推荐的 VOA / BBC Learning English / Wikipedia **国内不可达**（HTTP 000）
--    → 不在种子清单里（详见方案文档「实测修订」）
--
-- 🆕 `enabled` 列显式写出（2026-10-02）：以前省略（吃 `DEFAULT 1`），
--    而**只靠默认值就表达不了「这个源要禁用」** —— 新建库会把禁用的源又建回来。
--    📌 判据：**「默认值」只能表达「没意见」，表达不了「明确不要」** ——
--       凡是要显式说「不」的列，都必须写出来。
INSERT OR IGNORE INTO content_source
    (id, name, url, kind, category, cefr_hint, license, redistributable, tz_offset_min, enabled, created_at, updated_at)
VALUES
    (1, 'NPR News',      'https://feeds.npr.org/1001/rss.xml',                        'rss', 'news', 'B2', 'news',          1,    0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    -- ⚠️ ECNS 是**唯一**时间不带时区的源（`2026-09-29 21:34:24`）→ 按北京时间解释
    (2, 'ECNS 中国新闻网英文', 'https://www.ecns.cn/rss/rss.xml',                        'rss', 'news', 'B2', 'news',          1,  480, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    -- 🔴 **已禁用**（`enabled = 0` · 2026-10-02 白哥「如果真的不大用那就废弃」）
    --
    -- 实测数据（生产库快照）：
    --   · 33 条，占全库 **8.0%**；**32/33 条 < 300 词**（自身的可用性阈值）
    --   · 正文中位 **186 词**（五个源里最低；NPR 923 / Dev.to 768）
    --   · **33/33 全部含 `Read full article`** —— 即 RSS 给的**全是片段**
    --   · 🔴 文章页对**两种 UA 都返回 405** ⇒ 我们**拿不到它的全文**
    -- ⇒ 结论：不是选题不好（它的话题质量高），而是**拿不到可用内容**。
    --
    -- 保留本行（不删）的理由：`content_pool` 里已有 33 条历史数据，
    -- 删源会让它们变成孤儿；保留行 + `enabled = 0` 可随时改回 1。
    -- 📌 「禁用」≠「删除」—— 前者可逆、保留追溯性（同「已作废 ≠ 已删除」）。
    (3, 'Ars Technica',  'https://arstechnica.com/feed/',                             'rss', 'tech', 'C1', 'news',          1,    0, 0, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (4, 'Dev.to',        'https://dev.to/feed',                                       'rss', 'tech', 'B2', 'cc',            1,    0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (5, 'Hacker News',   'https://hacker-news.firebaseio.com/v0',                     'hn',  'tech', 'C1', 'public_domain', 1,    0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));
"#;

/// 初始化完整数据库 schema（核心表 + 管理表 + 偏好表 + 词库缓存表 + 额外索引）
pub fn init_database(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute_batch(SCHEMA_SQL)
        .map_err(|e| format!("core schema: {}", e))?;
    // ADMIN_SCHEMA_SQL 可能包含已在迁移中存在的列（如 permissions）
    // 此时 IF NOT EXISTS 仍可接受，捕获 duplicate column 错误
    match conn.execute_batch(ADMIN_SCHEMA_SQL) {
        Ok(_) => {}
        Err(e) => {
            let msg = e.to_string();
            if !msg.contains("duplicate column") {
                return Err(format!("admin schema: {}", msg));
            }
        }
    }
    conn.execute_batch(DISTRIBUTION_SCHEMA_SQL)
        .map_err(|e| format!("distribution schema: {}", e))?;
    conn.execute_batch(USER_PREFERENCES_SQL)
        .map_err(|e| format!("preferences table: {}", e))?;
    // 🆕 词库在线制卡缓存（LLM 兜底 · 服务端全局缓存）
    conn.execute_batch(WORDLIB_SCHEMA_SQL)
        .map_err(|e| format!("wordlib schema: {}", e))?;
    // 🆕 内容源 + 内容池（服务端共享内容池 · 2026-09-29 · 白哥定「先做后端」）
    //
    // 🔑 新表**不需要专门迁移**：`init_database` 每次启动**无条件**执行，
    //    而 `CREATE TABLE IF NOT EXISTS` 对「老库缺这张表」是**有效**的（会建出来）。
    //    ⚠️ 与「加列」不同 —— 加列的 `ALTER TABLE` 才是要写迁移的（见上方 §迁移）。
    conn.execute_batch(CONTENT_SCHEMA_SQL)
        .map_err(|e| format!("content schema: {}", e))?;
    // 🔴 2026-09-29 删除：`CREATE UNIQUE INDEX idx_users_phone_hash ON users(phone_hash)`
    //
    // 为什么**必须删**（两条独立理由，任一条都足以致命）：
    //   ① 新库：`SCHEMA_SQL` 已不再建 `phone_hash` 列 → 这里建索引会报
    //      `no such column: phone_hash` → `init_database` **整体失败**。
    //   ② 老库：该索引会让 `DROP COLUMN phone_hash` 失败
    //      （SQLite 规定：列被索引引用时不可删）→ 迁移卡住。
    //
    // 🔑 邮箱的唯一索引改到 `run_migrations_inner` 里 —— 它**必须**排在
    //    `ADD COLUMN email` 之后（索引引用列，列得先存在）。

    // ── 渐进式迁移 ──
    run_migrations_inner(conn)?;

    // ── 初始化默认数据 ──
    // 管理密钥认证（X-Admin-Key）返回的 admin_id="super" 需要存在于 admin_users 表中
    // 以满足 marketing_campaigns.created_by 等字段的 FK 约束
    let _ = conn.execute(
        "INSERT OR IGNORE INTO admin_users (id, username, password_hash, role, status, created_at) VALUES ('super', 'super', '', 'super', 'active', datetime('now'))",
        [],
    );

    Ok(())
}

/// 仅运行渐进式迁移（不重建表）。
/// 适用于已有生产 DB 的测试场景。
pub fn run_migrations(conn: &rusqlite::Connection) -> Result<(), String> {
    run_migrations_inner(conn)
}

fn run_migrations_inner(conn: &rusqlite::Connection) -> Result<(), String> {
    // 🔴 2026-09-29 清掉 **9 条对退役表的 ALTER**（`card_memory` ×1 · `user_cards` ×2 ·
    //    `prebuilt_plans` ×6）。它们被下面的容错**静默跳过**（报 `no such table` 被吞掉）——
    //    看着无害，实则**掩盖真错**：表名写错、字段写错都不会有任何反馈。
    //
    // 🔑 判据：「删数据」**≠**「让它不再产生」—— 一共三个面，都要一起清：
    //     ① 建表语句（否则新库把表建回来）② **迁移列表**（否则每库都白跑一遍）③ **测试断言**
    //    （否则断言退役表存在 → 必失败，且会把人往「把表加回来」的方向带）。
    //    本次清的是 ②③（① 已在 09-28/29 的前两轮清完）。
    // ══════════════════════════════════════════════════════════════════
    // 🔴 2026-09-29：users 表去掉「实名 + 手机号」5 列（白哥定：改用邮箱注册）
    // ══════════════════════════════════════════════════════════════════
    //
    // 删：`real_name` · `phone` · `phone_hash` · `id_number` · `bind_hash`
    // 加：`email`（唯一索引见下面 migrations 的末两条）
    //
    // # 🔴 为什么必须写在这里（而不是只改建表语句）
    //
    // `SCHEMA_SQL` 的 `CREATE TABLE IF NOT EXISTS` 对**已存在的库完全无效** ——
    // 见到表就跳过，不会比对结构。所以：
    // | 库 | 谁生效 |
    // |---|---|
    // | **全新库** | `SCHEMA_SQL`（已不含那 5 列）✅ |
    // | **已存在的库**（本地 + 生产 91 行） | **只有本节这段迁移** ✅ |
    //
    // # 🔴 顺序：**先删索引，再删列**
    //
    // SQLite 规定「**列被索引引用时不可 DROP**」，而 `idx_users_phone_hash`
    // 正引用 `phone_hash` → 不先删索引，删列会直接报错。
    // （该索引的**创建点**已从 `init_database` 移除，见那里的注释。）
    conn.execute("DROP INDEX IF EXISTS idx_users_phone_hash", [])
        .map_err(|e| format!("drop idx_users_phone_hash: {}", e))?;

    // # 🔑 为什么用 `drop_column_if_exists` 而不是「ALTER + 容错吞错」
    //
    // 若写成 `ALTER TABLE users DROP COLUMN x` 并把 `no such column` 加进容错白名单，
    // 那它会**连「列名拼错」一起吞掉** —— 写错一个字母 → 静默跳过 → 以为删成功了，
    // 而实际上那个列还在表里。**容错必须在「真的已经改过」时才放行。**
    // 这里改成「先查 `PRAGMA table_info` 确认列存在，再删」→ 幂等，且拼错会炸。
    for col in ["real_name", "phone", "phone_hash", "id_number", "bind_hash"] {
        drop_column_if_exists(conn, "users", col)?;
    }

    let migrations: &[&str] = &[
        // 🔴 2026-09-29 已删：`ALTER TABLE users ADD COLUMN phone_hash TEXT DEFAULT NULL`
        //    —— 该列已随「实名 + 手机号」一并移除（见上面的删列段）。
        // 分销模块新字段（已有数据库升级）
        "ALTER TABLE users ADD COLUMN subscription_expires TEXT DEFAULT NULL",
        "ALTER TABLE users ADD COLUMN referral_code TEXT",
        "ALTER TABLE users ADD COLUMN referred_by TEXT",
        "ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}'",
        // 退款支持字段
        "ALTER TABLE payment_orders ADD COLUMN refund_reason TEXT DEFAULT NULL",
        "ALTER TABLE payment_orders ADD COLUMN refund_id TEXT DEFAULT NULL",
        // 营销活动自定义海报系统提示
        "ALTER TABLE marketing_campaigns ADD COLUMN poster_prompt TEXT DEFAULT NULL",
        // users 表增加 referred_campaign_id：追踪注册来源活动
        "ALTER TABLE users ADD COLUMN referred_campaign_id TEXT DEFAULT NULL",
        // 唯一索引加入 order_id：同一用户不同订单可获多次佣金，登记注册只触发一次
        "DROP INDEX IF EXISTS idx_fulfillment_unique",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_fulfillment_unique ON reward_fulfillments(campaign_id, user_id, trigger_event, party, reward_type, order_id)",
        // 活动最小成团人数
        "ALTER TABLE marketing_campaigns ADD COLUMN min_member_count INTEGER DEFAULT 1",
        // 🔴 2026-09-29 已退役：defer_queue（V5/V6）—— 复习推迟调度改在端侧
        // ── 🆕 2026-09-29 邮箱注册 ──
        // ① 先加列（新库走 `SCHEMA_SQL` 已含此列 → 这里报 `duplicate column` → 容错放行）
        "ALTER TABLE users ADD COLUMN email TEXT DEFAULT NULL",
        // ② 再加索引 —— 🔑 **必须排在 ① 之后**：索引引用列，列得先存在，
        //    否则报 `no such column: email`（该错误**不在容错白名单**里 → 会炸，
        //    这正是想要的：漏了 ① 就该炸，而不是静默少一个唯一约束）。
        //
        // 🔑 用**部分索引**（`WHERE email IS NOT NULL`）而不是列上的 `UNIQUE` 约束：
        //    · trial 匿名账号的 email 为 NULL —— 而 SQLite 的 UNIQUE 允许**多行 NULL**，
        //      所以严格说列级 UNIQUE 也能用；但部分索引把「唯一性只约束真实邮箱」
        //      这个意图**写在定义里**，读代码的人不必去查 NULL 语义。
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email) WHERE email IS NOT NULL",
        // ── 🆕 2026-09-29 内容池：抓正文的尝试记录 ──
        // 新库走 `CONTENT_SCHEMA_SQL` 已含此列 → 这里对它们报 `duplicate column` → 容错放行。
        // 🔴 对**已存在的库**（本地开发库 / 将来的生产库）这是**唯一**的补列途径 ——
        //    `CREATE TABLE IF NOT EXISTS` 见到表就跳过，**不会**比对结构。
        //    这正是本文件反复强调的「加列必须写迁移」。
        "ALTER TABLE content_pool ADD COLUMN body_attempted_at TEXT",
    ];
    for sql in migrations {
        match conn.execute(sql, []) {
            Ok(_) => {}
            Err(e) => {
                let err_msg = e.to_string();
                // ⚠️ 容错只在**真的已经改过**时放行：`duplicate column` / `already exists`。
                //    🔴 **不再吞 `no such table`** —— 上面已清掉退役表的 ALTER，
                //       现在每条 ALTER 的目标表都由本函数的调用方 `init_database` 先行建好，
                //       所以 `no such table` = **真 bug**，必须炸出来（这正是「掩盖真错」的修法）。
                if !err_msg.contains("duplicate column") && !err_msg.contains("already exists") {
                    return Err(format!("migration failed: {} — SQL: {}", err_msg, sql));
                }
            }
        }
    }
    Ok(())
}

/// 条件删列 —— **列存在才删**（幂等：跑多次安全）。
///
/// # 为什么需要它（而不是 `ALTER TABLE ... DROP COLUMN` + 容错吞错）
///
/// `ALTER TABLE x DROP COLUMN y` 在列**不存在**时会报 `no such column: y`。
/// 若把这条错误加进 `run_migrations_inner` 的容错白名单，就会**连带吞掉
/// 「列名拼错」**——写错一个字母 → 静默跳过 → 看起来「迁移成功了」，
/// 而那个列**还在表里**（下一轮有人再引它，就会以「列还在」为前提写代码）。
///
/// 🔑 判据：**容错必须在「真的已经改过」时才放行** ——
///    「我要删的列不存在」有两种原因：① 已删过（该放行）② 名字写错（该炸）。
///    吞错版本无法区分这两者；查 `PRAGMA table_info` 可以。
///
/// # ⚠️ 调用前置条件
/// 若该列被**索引**引用，SQLite 会**拒绝 DROP**（报错而非静默）。
/// 所以调用方必须先 `DROP INDEX`（见 `run_migrations_inner` 里删 `idx_users_phone_hash`）。
fn drop_column_if_exists(
    conn: &rusqlite::Connection,
    table: &str,
    column: &str,
) -> Result<(), String> {
    let exists = {
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", table))
            .map_err(|e| format!("pragma table_info({}): {}", table, e))?;
        let mut rows = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|e| format!("query table_info({}): {}", table, e))?;
        rows.any(|r| r.map(|name| name == column).unwrap_or(false))
    };

    if !exists {
        return Ok(());
    }

    conn.execute(&format!("ALTER TABLE {} DROP COLUMN {}", table, column), [])
        .map_err(|e| format!("drop column {}.{}: {}", table, column, e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    /// 期望的**全部**表 —— 与 `sqlite_master`（排除 `sqlite_*` 内部表）**集合相等**。
    ///
    /// 🔑 为什么用「集合相等」而不是「包含断言 + 数量下限」：
    ///    后者**只能发现缺表，发现不了多表** —— 退役表留在常量里会一直「通过」，
    ///    直到有人误以为它还在用。集合相等两头都卡。
    ///    （09-29 之前这里列着 `achievements` / `user_cards` / `prebuilt_*` … 共 38 项，
    ///     实际只建 20 张 → 3 个测试失败，全指向已退役的表。）
    const EXPECTED_TABLES: &[&str] = &[
        // 核心
        "users",
        "tokens",
        "trial_ip_log",
        // 管理端
        "admin_users",
        "admin_audit_log",
        "subscription_requests",
        "subscription_plans",
        "payment_orders",
        "subscription_audit_log",
        // 分销营销
        "marketing_campaigns",
        "referral_clicks",
        "distribution_commissions",
        "distribution_expenses",
        "reward_fulfillments",
        "campaign_members",
        "user_notifications",
        // 配置 / 偏好
        "app_config",
        "user_preferences",
        // 🆕 词库在线制卡（A1）
        "generated_card_cache",
        "generated_card_hit",
        // 🆕 内容源 + 内容池（2026-09-29 · 服务端共享内容池）
        // ⚠️ 方案 §4.3 还列了 `user_read` / `user_interest` —— **有意不建**：
        //    前者与端侧 `article_read` 是同一个口径的第二个出处；
        //    后者设计未定（「兴趣怎么影响排序」还没做）。见 `CONTENT_SCHEMA_SQL`。
        "content_source",
        "content_pool",
    ];

    /// 已**彻底退役**的表 —— 出现在库里即说明「退役没做干净」。
    const RETIRED_TABLES: &[&str] = &[
        // 对话链
        "conversations",
        "conversation_turns",
        // 后端 FSRS 复习状态（已迁端侧 user.db）
        "card_memory",
        "review_log",
        "user_cards",
        "user_science_cards",
        "user_language_cards",
        "user_literature_cards",
        "user_humanities_cards",
        "card_relations",
        "defer_queue",
        // K12 计划体系（整体清退）
        "user_plan_progress",
        "prebuilt_plans",
        "prebuilt_stages",
        "prebuilt_tasks",
        "prebuilt_cards",
        "prebuilt_science_cards",
        "prebuilt_language_cards",
        "prebuilt_literature_cards",
        "prebuilt_humanities_cards",
        "plan_runs",
        "guardian_assignments",
        "k12_quiz_bank",
        "k12_quiz_attempts",
        // 成就（改为端侧计算）
        "achievements",
        // admin 调试面板
        "debug_trackers",
        "debug_logs",
    ];

    /// 更早期迁移遗留的旧表名
    const FORBIDDEN_OLD_TABLES: &[&str] = &["cards", "conversation_plans", "learning_plans"];

    fn actual_tables(conn: &Connection) -> Vec<String> {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .unwrap();
        stmt.query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .filter(|n| !n.starts_with("sqlite_")) // sqlite_sequence 等内部表
            .collect()
    }

    /// 验证完整 `init_database()` 后的表集合：**恰好等于**期望，且退役表一张不剩
    #[test]
    fn test_full_schema_all_tables_present() {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        let actual = actual_tables(&conn);
        let mut expect: Vec<String> = EXPECTED_TABLES.iter().map(|s| s.to_string()).collect();
        expect.sort();

        let missing: Vec<&String> = expect.iter().filter(|t| !actual.contains(t)).collect();
        let extra: Vec<&String> = actual.iter().filter(|t| !expect.contains(t)).collect();
        assert!(missing.is_empty(), "缺表: {:?}", missing);
        assert!(extra.is_empty(), "多出未登记的表: {:?}", extra);

        for tbl in RETIRED_TABLES {
            assert!(
                !actual.contains(&tbl.to_string()),
                "退役表 {} 又被建回来了",
                tbl
            );
        }
        for tbl in FORBIDDEN_OLD_TABLES {
            assert!(!actual.contains(&tbl.to_string()), "旧表 {} 仍然存在", tbl);
        }
    }

    /// 验证现役表的关键列 —— 含**迁移新增**的列（全新库靠 `SCHEMA_SQL`，老库靠 `run_migrations_inner`）
    #[test]
    fn test_core_table_columns() {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        // users：注册标识（邮箱）/ 分销 / 软删除
        let cols = table_columns(&conn, "users");
        for c in [
            "id",
            "username",
            "email",
            "deleted_at",
            "subscription_expires",
            "referral_code",
            "referred_by",
            "referred_campaign_id",
        ] {
            assert!(cols.contains(&c.to_string()), "users 缺 {}", c);
        }

        // 🔴 反向断言：微信时代的「实名 + 手机号」5 列**必须不存在**（2026-09-29 删除）。
        //
        // 🔑 为什么必须断言「不存在」，而不是只断言 `email` 存在：
        //    后者只能证明**新列加上了**，证明不了**旧列删掉了**。
        //    而旧列残留正是「语义残留」的来源 —— 列还在，后续开发就会
        //    误以为「实名还能用」，不断把相关 SELECT / 展示加回来。
        //    **断言的倾向性决定它能防住什么**：这里要防的是「列被加回来」。
        for c in ["real_name", "phone", "phone_hash", "id_number", "bind_hash"] {
            assert!(
                !cols.contains(&c.to_string()),
                "users 仍有已删列 `{}` —— 实名/手机号是微信时代遗留，2026-09-29 已改邮箱注册",
                c
            );
        }

        // admin_users：迁移新增的 permissions
        let cols = table_columns(&conn, "admin_users");
        assert!(
            cols.contains(&"permissions".to_string()),
            "admin_users 缺 permissions"
        );

        // payment_orders：退款字段来自迁移
        let cols = table_columns(&conn, "payment_orders");
        for c in [
            "status",
            "prepay_id",
            "transaction_id",
            "refund_reason",
            "refund_id",
        ] {
            assert!(cols.contains(&c.to_string()), "payment_orders 缺 {}", c);
        }

        // marketing_campaigns：迁移新增列
        let cols = table_columns(&conn, "marketing_campaigns");
        for c in ["poster_prompt", "min_member_count", "created_by"] {
            assert!(
                cols.contains(&c.to_string()),
                "marketing_campaigns 缺 {}",
                c
            );
        }

        // reward_fulfillments：唯一索引重构依赖 order_id
        let cols = table_columns(&conn, "reward_fulfillments");
        assert!(
            cols.contains(&"order_id".to_string()),
            "reward_fulfillments 缺 order_id"
        );

        // 🆕 词库在线制卡缓存（A1）
        let cols = table_columns(&conn, "generated_card_cache");
        for c in [
            "spelling",
            "card_content",
            "contract_version",
            "source",
            "hit_count",
            "distinct_user_count",
            "created_at",
            "updated_at",
        ] {
            assert!(
                cols.contains(&c.to_string()),
                "generated_card_cache 缺 {}",
                c
            );
        }
        let cols = table_columns(&conn, "generated_card_hit");
        for c in ["spelling", "device_id", "first_hit_at", "hit_count"] {
            assert!(cols.contains(&c.to_string()), "generated_card_hit 缺 {}", c);
        }

        // 🆕 内容源 + 内容池（2026-09-29 · 服务端共享内容池）
        let cols = table_columns(&conn, "content_source");
        for c in [
            "id",
            "name",
            "url",
            "kind",
            "category",
            "cefr_hint",
            "license",
            "redistributable",
            "fetch_interval_min",
            "enabled",
            "last_fetch_at",
            "fail_count",
            "created_at",
            "updated_at",
        ] {
            assert!(cols.contains(&c.to_string()), "content_source 缺 {}", c);
        }
        let cols = table_columns(&conn, "content_pool");
        for c in [
            "id",
            "source_id",
            "title",
            "summary",
            "body",
            "url",
            "author",
            "category",
            "published_at",
            "fetched_at",
            "word_count",
            "score",
            "comments",
            // 🆕 抓正文的尝试记录 —— 缺了它「只试一次」的语义会静默失效
            "body_attempted_at",
        ] {
            assert!(cols.contains(&c.to_string()), "content_pool 缺 {}", c);
        }

        // 🔴 **反向断言**：方案 §4.3 里的这两张表**有意不建** ——
        //    锁住「学习状态迁端侧」这条后手决策，防止有人照 09-25 的方案把表加回来
        //    （那会造成「同一个口径两个出处」：端侧 `article_read` vs 服务端 `user_read`）。
        for t in ["user_read", "user_interest"] {
            let exists: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    rusqlite::params![t],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            assert_eq!(
                exists, 0,
                "🔴 `{}` 不该存在 —— 见 CONTENT_SCHEMA_SQL 的说明（学习状态已迁端侧）",
                t
            );
        }

        // 种子源：实测**可达**的 5 个（VOA/BBC/Wikipedia 因国内不可达**不在内**）
        let seeded: i64 = conn
            .query_row("SELECT COUNT(*) FROM content_source", [], |r| r.get(0))
            .unwrap();
        assert_eq!(seeded, 5, "种子源应为 5 个（实测可达清单）");

        // 🔴 种子源里**不得**出现不可达的源（防止照旧方案加回 VOA/BBC）
        for bad in ["voanews", "bbc.co", "wikipedia"] {
            let n: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM content_source WHERE lower(url) LIKE ?1",
                    rusqlite::params![format!("%{}%", bad)],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(
                n, 0,
                "🔴 种子源不该含 `{}`（2026-09-29 实测国内不可达）",
                bad
            );
        }
    }

    /// 🔴 迁移演练：**旧结构的库**（含实名/手机号 5 列 + 旧索引）跑 `init_database` 后
    /// 必须变成新结构，且**数据不丢**、**可重复执行**。
    ///
    /// # 为什么必须有这个测试（而不是「改完建表语句就完事」）
    ///
    /// `CREATE TABLE IF NOT EXISTS` 对**已存在的库完全无效**（见到表就跳过，不比对结构）。
    /// 于是「改 schema」这件事存在**两条互不相干**的路径：
    ///
    /// | 库 | 谁生效 | 谁验证 |
    /// |---|---|---|
    /// | **全新库** | `SCHEMA_SQL` 建表 | `test_core_table_columns` ✅ |
    /// | **已存在的库**（本地 + 生产 91 行） | **`run_migrations_inner` 的删列段** | **本测试** ✅ |
    ///
    /// 🔑 不测这条就会出现最坏情况：**新库测试全绿、生产库起不来**
    ///    （2026-09-29 词形表那次就是「注释写对、生产行为没验」的反面教材）。
    ///
    /// ⚠️ 本测试**故意用旧结构建表** —— 不能用 `init_database` 建（那已经不是旧结构了，
    ///    测的会是「新库跑两遍」，恰好绕开真正要验的那条路径）。
    #[test]
    fn test_migrate_from_legacy_users_table() {
        let conn = Connection::open_in_memory().unwrap();

        // ① 造「旧结构」：含那 5 列 + 引用 phone_hash 的旧索引
        //
        // ⚠️ `referred_campaign_id` **不写 `REFERENCES marketing_campaigns(id)`** ——
        //    该表此刻还不存在，而本连接的 `foreign_keys` 是 ON →
        //    建表会报 `no such table: main.marketing_campaigns`。
        //    FK 声明与本次迁移无关（删列不碰它），去掉即可，不影响真实性。
        conn.execute_batch(
            r#"
            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT,
                streak_days INTEGER DEFAULT 0,
                last_active_date TEXT,
                display_name TEXT DEFAULT NULL,
                real_name TEXT DEFAULT NULL,
                phone TEXT DEFAULT NULL,
                phone_hash TEXT DEFAULT NULL,
                id_number TEXT DEFAULT NULL,
                bind_hash TEXT DEFAULT NULL,
                deleted_at TEXT DEFAULT NULL,
                subscription_expires TEXT DEFAULT NULL,
                referral_code TEXT UNIQUE,
                referred_by TEXT REFERENCES users(id),
                referred_campaign_id TEXT,
                created_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL;
            INSERT INTO users (id, username, real_name, phone, phone_hash, bind_hash, created_at)
                VALUES ('u1', 'test1', '张三', '13800000000', 'hash1', 'bh1', '2026-01-01');
            "#,
        )
        .unwrap();

        // ② 跑初始化 → 应完成迁移（含「先删索引、再删列」）
        init_database(&conn).expect("旧库迁移失败");

        // ③ 结构：email 已加，5 列已删
        let cols = table_columns(&conn, "users");
        assert!(
            cols.contains(&"email".to_string()),
            "迁移后 users 应新增 email 列"
        );
        for c in ["real_name", "phone", "phone_hash", "id_number", "bind_hash"] {
            assert!(
                !cols.contains(&c.to_string()),
                "迁移后 users 不应还有列 `{}`",
                c
            );
        }

        // ④ 旧索引也必须消失 —— 否则新库上会「索引引用不存在的列」
        let idx_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_users_phone_hash'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(idx_count, 0, "旧索引 idx_users_phone_hash 应已删除");

        // ⑤ **数据不丢** —— 这条区分「迁移」与「删表重建」
        let (username, created): (String, String) = conn
            .query_row(
                "SELECT username, created_at FROM users WHERE id = 'u1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(username, "test1");
        assert_eq!(created, "2026-01-01");

        // ⑥ **幂等**：服务每次启动都会跑迁移 → 必须能重复执行不报错
        //    （删列靠 `drop_column_if_exists` 保证；新库路径靠 `duplicate column` 容错）
        init_database(&conn).expect("重复执行迁移应无错（幂等）");
    }

    fn table_columns(conn: &Connection, table: &str) -> Vec<String> {
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", table))
            .unwrap();
        stmt.query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect()
    }
}
