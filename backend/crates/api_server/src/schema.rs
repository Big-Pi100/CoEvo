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
/// 内容分类的**受控词表**（唯一权威定义处）。
///
/// # 为什么要有这个常量
/// 词表要同时被**三处**使用：① 建表 CHECK ② 种子源配置 ③ 断言。
/// 各写一份就会漂移 —— 本项目已多次踩过「同一件事的口径散在多处」。
/// ⇒ 集中在这里，其余地方引用它。
///
/// # 🔴 这 8 个值的来历（**不是拍脑袋定的**）
/// 定稿 → `docs/design/english-app-implementation-plan-v2-2026-09-25.md` §10.3.1：
/// 「扩到 **7** 个 category，删掉 `life`」——
/// `tech | business | science | sports | culture | entertainment | health`。
/// 理由是「**兴趣标签是用户可见的**，粒度决定『按我兴趣推』的感知强度」，
/// 并要求与兴趣选择界面的 7 个标签 **1:1 映射**。
///
/// 🆕 **`news` 是白哥 2026-10-02 追加的第 8 个值**：
/// · 定稿两版**都没有** `news`（原设计评估的 VOA / BBC 都不可达，当时没有新闻源）
/// · 它是**实现期**为 NPR / ECNS 临时加的，一直没进设计文档
/// · 而「综合 / 国际新闻」确实**不属于任何兴趣类** ⇒ 硬塞类会不准
/// ⇒ 白哥定：**保留 `news`**（卡片显示 `News`），其余按定稿收敛。
///
/// ⚠️ **已删掉 `life`**（定稿理由：「生活」太糊 —— 睡眠算健康还是生活？）。
///    生产库现有源**无一个**用 `life` ⇒ 删除零影响。
///
/// ✅ **`sports` / `entertainment` 已于 2026-10-02 补源**（seed id 13 / 14）——
///    `NPR Sports`(`feeds.npr.org/1055`) · `NPR Movies`(`feeds.npr.org/1045`)。
///    🔴 **两个 feed ID 是逐个抓 `<title>` 确认的，不是从记忆里抄的** ——
///       第一轮据「NPR 有 Movies 频道」直接请求 1045，返回**空 body**，
///       差点误判成「该频道不存在」；并发重扫 ID 段才确认。
///       📌 判据：**ID → 频道名必须由 `<title>` 确认**。
///    实测 → `docs/review/sports-entertainment-source-2026-10-02.md`
///
/// # 🆕 2026-10-02 三轮：扩到 **12** 类
///
/// 白哥：「『8 类之外』但存在的高价值频道 —— 这些要接入，而且**如果不能归类
/// 的话可以增加新的分类**」。⇒ 新增 4 类：`education` / `history` / `law` / `family`。
///
/// 🔑 **本轮最值钱的判据：区分「独立话题」与「跨类编辑栏目」**
///
/// NPR 扫出的 71 个活跃频道里，有一批**不是话题，而是「同一批内容的另一种呈现」**：
///   `Opinion` · `Analysis` · `Perspective` · `Obituaries` · `Race` · `On Disabilities`
///
/// 它们的内容**分属各类** —— 实测 `Obituaries` 一轮里同时有
/// 「纪念爵士 John Coltrane」(`culture`)、「画家 Sliman Mansour」(`culture`)、
/// 「NPR 编辑逝世」(`news`)；`Race` 一轮里同时有学校选择 (`education`)、
/// Kaepernick (`sports`)、Dolly Parton (`culture`)。
/// ⇒ 给它们建类会让**分类自相矛盾**（一条内容两个类）⇒ **不接**。
///    🔴 **这是白哥 2026-10-02 明确决定，不是遗漏** —— 将来若要接，
///       **不要**直接建 category，应作为**另一个维度**（如「深度 / 观点」标签），
///       与 category 正交。详见 `docs/review/category-expansion-and-source-onboarding-2026-10-02.md`。
/// 📌 判据：**「这个 feed 切的是话题，还是视角？」**
///
/// 🔑 能归入现有类的就**不新增**（避免用户可见的兴趣标签膨胀）：
///      `Religion` / `Architecture` → `culture`（建筑与信仰是文化）
///      `Weather` → `science`（气象是地球科学）· `Strange News` / `Media` → `news`
///      `On Aging` → `health`
///
/// ⚠️ **兴趣标签是用户可见的**（定稿 §10.3.1）⇒ **12 个已是上限**；
///    再加就该先合并（例如把 `law` 并入 `news`、`family` 并入 `health`）。
///    ✅ 兴趣选择界面**尚未实现**（端侧只有 `feed_item.dart` 的显示映射）
///    ⇒ 新增类的成本只是「本词表 + 端侧 map」两处。
pub const CONTENT_CATEGORIES: &[&str] = &[
    "news",
    "tech",
    "business",
    "science",
    "sports",
    "culture",
    "entertainment",
    "health",
    // ── 🆕 2026-10-02 三轮新增（白哥批准「不能归类可以增加新分类」）──
    "education",
    "history",
    "law",
    "family",
];

/// 内容源表（**建表**部分）。
///
/// # 🔴 为什么这一句要单独成常量（而不是塞在一条大 SQL 里）
///
/// 因为**重建表**（`rebuild_content_source_with_check`）必须复用**同一份** DDL ——
/// 否则「新库的表」与「重建出的表」会变成两份定义，**必然漂移**。
/// 📌 判据：**同一件事的口径只能有一处权威**（本项目已多次踩过「口径散落」）。
pub const CONTENT_SOURCE_TABLE_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS content_source (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    name               TEXT    NOT NULL,
    url                TEXT    NOT NULL,
    kind               TEXT    NOT NULL DEFAULT 'rss',   -- rss | hn
    -- 🔑 受控词表 —— 见 `CONTENT_CATEGORIES`（单一定义处）
    --
    -- ⚠️ CHECK 在这里**是**有意义的（改错类会立刻报错），但有两条**必须知道**：
    --   ① **新库**靠**这句**建出 CHECK；**旧库**靠
    --      `rebuild_content_source_with_check()` **重建表**拿到
    --      （`CREATE TABLE IF NOT EXISTS` 对已存在的表无效，而 SQLite
    --       **不支持 `ALTER TABLE ADD CONSTRAINT`** ⇒ 重建是唯一途径）。
    --      ✅ 2026-10-02 起**两条路都有** ⇒ 新库/旧库的约束一致（不再有「只对新库生效」）。
    --   ② seed 用 `ON CONFLICT DO NOTHING`（**不是** `INSERT OR IGNORE`）——
    --      前者只忽略**重复**，**CHECK 违规会正常报错** ⇒ 新源写错分类**立刻炸**，
    --      而不是静默丢一个源。
    --      🔴 **若有人把它改回 `INSERT OR IGNORE`，「静默丢源」会立刻回来。**
    --   ③ 词表与 CHECK 的同步由 `test_content_source_check_matches_categories`
    --      （读 DDL 逐类比对，集合相等）兜住。
    category           TEXT
        CHECK (category IN ('news','tech','business','science','sports',
                            'culture','entertainment','health',
                            'education','history','law','family')),
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

"#;

/// `content_source` 的索引 —— **与建表分开**，因为重建时**顺序有讲究**：
/// 旧表被 `DROP` 时它的索引（同名）一并消失，**之后**才能建新索引；
/// 若索引与建表写在同一批 SQL 里、且旧索引还占着名字，
/// `CREATE INDEX IF NOT EXISTS` 会**静默跳过**（名字冲突）⇒ 新表**没有唯一索引**
/// ⇒ 之后 seed 的 `ON CONFLICT (url)` 会失败。
/// 📌 判据：**`IF NOT EXISTS` 遇到「名字被别的表占着」时会假装成功。**
pub const CONTENT_SOURCE_INDEX_SQL: &str = r#"
CREATE UNIQUE INDEX IF NOT EXISTS idx_csrc_url ON content_source (url);
CREATE INDEX IF NOT EXISTS idx_csrc_due ON content_source (enabled, last_fetch_at);
"#;

/// 内容池表 + 其索引。
pub const CONTENT_POOL_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS content_pool (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- = 端侧的 article_id（见上方说明）
    source_id    INTEGER REFERENCES content_source(id),
    title        TEXT    NOT NULL,
    summary      TEXT,                                -- 摘要（RSS description）
    body         TEXT,                                -- 全文（仅 redistributable=1 的源）
    url          TEXT    NOT NULL,
    author       TEXT,                                -- dc:creator（⚠️ 不放 service 层做展示决策）
    -- 内容分类（入库时**从 `content_source.category` 拷**，不是 RSS 的自由标签）
    -- 🔑 取值见 `CONTENT_CATEGORIES`。
    --
    -- 🔴 **本列故意不加 `CHECK`**（虽然定稿 §10.3.1 写了）——
    --    因为入库用的是 `INSERT OR IGNORE`，而 SQLite 的 OR IGNORE
    --    **会把 CHECK 违规一并忽略** ⇒ 结果是**静默丢内容**（用户看不到、日志也没有）。
    --    这正是本项目最忌讳的「静默失败」，比「没有约束」更糟。
    --    ⇒ 约束改在**上游**做：`content_source.category` 有 CHECK（配置表、改了会报错），
    --      且源配置被断言锁住 ⇒ `content_pool` 拿到的值天然合法。
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
-- 🆕 保留期清理的查询列（`prune_old_content` 按 `fetched_at` 排序 + 过滤）
-- ⚠️ 没有它：每轮清理都要**全表扫** content_pool（将来几万行时就是每 6 小时一次全扫）
CREATE INDEX IF NOT EXISTS idx_cpool_fetched  ON content_pool (fetched_at);
"#;

/// **种子源**（实测**可达**才进这份清单 —— 2026-09-29 本机 + VPS 双实测）
///
/// # 🔴 为什么用 `ON CONFLICT DO NOTHING` 而**不是** `INSERT OR IGNORE`
///
/// 两者都幂等，但**差一条关键的**：
/// · `INSERT OR IGNORE` 忽略**任何**约束冲突 —— **包括 CHECK 违规**
///   ⇒ 新源的 `category` 写错时**静默丢源**（本项目最忌讳的「静默失败」）
/// · `ON CONFLICT DO NOTHING` 只忽略**冲突**（唯一约束/主键），
///   **CHECK 违规会正常报错** ⇒ 写错类**立刻炸**
/// 📌 判据：**要「忽略重复」就只忽略重复，别用「忽略一切」的语法。**
pub const CONTENT_SEED_SQL: &str = r#"
-- 🔴 曾经推荐的 VOA / BBC Learning English / Wikipedia **国内不可达**（HTTP 000）
--    → 不在种子清单里（详见方案文档「实测修订」）
--
-- 🆕 `enabled` 列显式写出（2026-10-02）：以前省略（吃 `DEFAULT 1`），
--    而**只靠默认值就表达不了「这个源要禁用」** —— 新建库会把禁用的源又建回来。
--    📌 判据：**「默认值」只能表达「没意见」，表达不了「明确不要」** ——
--       凡是要显式说「不」的列，都必须写出来。
INSERT INTO content_source
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
    (5, 'Hacker News',   'https://hacker-news.firebaseio.com/v0',                     'hn',  'tech', 'C1', 'public_domain', 1,    0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),

    -- ═══════════════════════════════════════════════════════════════════════
    -- 🆕 2026-10-02 扩充（白哥「其他类型的信息不太够」+「这样tech就差不多」）
    --
    -- 每条都经**真实 `fetch_source_items`**（生产同款代码）实测才写入 ——
    -- 见 `docs/review/source-expansion-2026-10-02.md` 与
    -- `examples/eval_candidate_sources.rs`（可复用的评估工具）。
    -- 📌 判据：**接入前必须用真实实现验一遍**（自己复刻一遍 = 引入新的偏差源）。
    -- ═══════════════════════════════════════════════════════════════════════

    -- ── NPR 6 个分频道：一个源覆盖 6 个兴趣领域 ─────────────────────────
    --
    -- 🔑 **为什么优先它**：
    --   ① NPR 是本轮实测**质量最好**的源（正文 4/4 达标 · 全文 1000–3300 词）
    --   ② 分频道是**同一个媒体** ⇒ `license` / `redistributable` 条款与现有
    --      `NPR News`(id=1) **完全相同** ⇒ 零新增合规风险
    --   ③ 把兴趣领域从 **2 类（news/tech）扩到 7 类** —— 补掉「其他类型不够」
    --   ④ 纯配置：无代码、无解析器、无新 `kind`
    -- 实测（2026-10-02）：6 个频道全部 HTTP 200 · 各 10 条 · 摘要中位 28–30 词
    -- · 网页提取 3/4–4/4 达标 · **营销内容 0**
    (6,  'NPR World 国际',    'https://feeds.npr.org/1004/rss.xml', 'rss', 'news',     'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (7,  'NPR Business 商业', 'https://feeds.npr.org/1006/rss.xml', 'rss', 'business', 'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (8,  'NPR Science 科学',  'https://feeds.npr.org/1007/rss.xml', 'rss', 'science',  'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (9,  'NPR Culture 文化',  'https://feeds.npr.org/1008/rss.xml', 'rss', 'culture',  'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (10, 'NPR Technology',    'https://feeds.npr.org/1019/rss.xml', 'rss', 'tech',     'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    -- ⚠️ `health` 是**已定稿规格里的值**（`implementation-plan-v2` §10.3.1 的 7 类），
    --    不是临时发明。端侧 `feed_item.dart` 的 `_categoryLabels` 同步加了它。
    (11, 'NPR Health 健康',   'https://feeds.npr.org/1128/rss.xml', 'rss', 'health',   'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),

    -- ── arXiv（白哥指定）：学术语料，量大且「句末完整率 100%」 ────────────
    --
    -- 🔑 实测：269 条/天（cs.CL）· abstract 中位 **202 词** · **句末完整 100%**
    --    （对照：HackerNoon 70% · 已废弃的 Ars **0%**）。
    --    还有 `/html/` 全文版（覆盖 14/15=93% · 提取 9992 词），但**本行不启用**
    --    —— 见下面的 `redistributable = 0`。
    --
    -- 🔴 **`redistributable = 0` 的依据（实测许可原文，2026-10-02）**：
    --    arXiv 的许可是**逐篇由作者选择**的，可选
    --    `CC BY / CC BY-SA / CC BY-NC-SA / CC BY-NC-ND / arXiv 永久非独占许可`。
    --    其中 arXiv 默认许可的原话是：
    --      「**limited rights to arXiv to distribute the article, and also
    --        limits re-use of any type from other entities or individuals**」
    --    ⇒ **明确限制其他实体的再使用** ⇒ 我们不抓 `/html/` 全文，
    --      只入库 RSS 提供的 abstract（进 `summary`）+ 原文链接。
    --    📌 `write_items` 会因 `redistributable = 0` 丢弃 `body`（实测确认）。
    --    ⚠️ 若将来要展示全文，**必须先逐篇核对许可**（`license='mixed'` 就是这个意思）。
    --
    -- ⚠️ **语域是学术英语（C1+）**：术语密集、句法复杂。
    --    是否适合目标用户是**产品决定**（白哥），不是技术问题。
    -- ⚠️ `cs.AI + cs.LG + cs.CL` 每天合计 1400+ 条，远超需求
    --    ⇒ 本行**只接 cs.CL**（与「语言」最贴，269 条/天）。
    -- `tz_offset_min = 0`：arXiv 用 RFC 2822 时间戳（自带时区），本列不生效。
    (12, 'arXiv cs.CL',  'https://export.arxiv.org/rss/cs.CL', 'rss', 'science', 'C1', 'mixed', 0, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),

    -- ═══════════════════════════════════════════════════════════════════════
    -- 🆕 2026-10-02 二轮：`sports` / `entertainment` 补源
    --    白哥：「sports / entertainment 要补源」——
    --    这两个值在受控词表里（定稿 §10.3.1 的 7 类），但**一直没有源**。
    --
    -- 🔑 **为什么仍选 NPR**：与 id=1 是**同一媒体** ⇒ `license` / `redistributable`
    --    条款**逐字相同** ⇒ **零新增合规风险**；且纯配置（无代码、无新 `kind`）。
    --    实测（真实 `fetch_source_items` + `fetch_article_body_diagnostic`）：
    --    · Sports 3/4 达标 · Movies 4/4 达标 · **营销 0** · 正文 906–2099 词
    --    · 与对照的 `NPR News` 同构（同样「RSS 只给摘要 → 抓网页」）
    --
    -- ❌ **实测后排除的非 NPR 候选**（理由见报告，不接）：
    --    · ESPN NFL —— 量最大（31 条/轮 ≈ 124/天 · 4/4 达标），但摘要中位仅 **20 词**
    --      （NPR 32 词），且尾部会粘作者列表；**若要更大量再单独评估**
    --    · CBS Sports —— 🔴 **curl 200 但 reqwest 请求失败**（同 Ars 405 那类「工具差异」）
    --    · Variety / Hollywood Reporter —— 质量达标记，但**要抓网页 + 与 NPR 不同媒体**
    --      ⇒ 引入新的许可判断；在无增量收益时不值得（NPR 已覆盖这两个类）
    --    · 已实测**不可达**：The Guardian / BBC Sport / Sky Sports / Deadline / NBC News（502）
    --      · Bleacher Report / EW / AP / Yahoo Sports（403）· SI / Vulture / IGN（404）
    -- ═══════════════════════════════════════════════════════════════════════
    (13, 'NPR Sports 体育',  'https://feeds.npr.org/1055/rss.xml', 'rss', 'sports',        'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (14, 'NPR Movies 影视',  'https://feeds.npr.org/1045/rss.xml', 'rss', 'entertainment', 'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),

    -- ═══════════════════════════════════════════════════════════════════════
    -- 🆕 2026-10-02 三轮：「8 类之外」的独立话题频道（白哥「这些要接入」）
    --
    -- 🔑 **选择标准 = 「切话题」而不是「切视角」**（见 `CONTENT_CATEGORIES` 的说明）。
    --    下列 10 个都经真实 `fetch_source_items` + `fetch_article_body_diagnostic` 实测：
    --    **营销 0 · 摘要中位 27–31 词 · 网页提取 3/4 或 4/4 达标**（与对照 NPR News 同档）。
    --
    -- 🔑 **重叠实测**：与最可能重复的已接频道比 `<link>` 集合 —— **0–17%**
    --    （Education↔Culture 17% · Law↔News 17% · 其余 0%）
    --    ⇒ **都是独立内容池**，接它们不会造成内容重复。
    --
    -- 🔑 **4 个新类的归属理由**（`education`/`history`/`law`/`family` 各只有一个源）：
    --    · `education` —— 无法归入任何现有类（`culture` 是艺术、`news` 太泛）
    --    · `history`   —— 独立学科（`culture` 装不下「人口普查史 / 考古」）
    --    · `law`       —— 独立领域（`business` 是经济，装不下「死刑 / 最高法院」）
    --    · `family`    —— 定稿删掉的是 `life`（理由「太糊」），而 `family`
    --                    很具体（育儿假 / 托儿成本 / 照护父母）⇒ 不是同一个东西
    --
    -- ⚠️ **不加 `CHECK` 就不用管**（pool 那侧）—— 但本表**有** CHECK，
    --    所以新类必须同步进上面的 `CHECK (...)`，否则**新库**会静默丢源
    --    （`INSERT OR IGNORE` 吞 CHECK 违规）。已由断言兜住。
    --
    -- ❌ **不接「跨类编辑栏目」**（🔴 白哥 2026-10-02 **明确决定**，不是遗漏，
    --    别看到「少一个源」就顺手补上）：`Opinion` 1057 · `Analysis` 1059 ·
    --    `Perspective` 1166 · `Obituaries` 1062 · `Race` 1015 · `On Disabilities` 1133）——
    --    它们的内容分属各类（详见 `CONTENT_CATEGORIES` 的说明），建类会自相矛盾。
    --    ⚠️ 它们**质量并不差**（实测 4/4 达标）—— 不接是**归类口径**的决定，不是质量问题。
    -- ═══════════════════════════════════════════════════════════════════════
    (15, 'NPR Education 教育',   'https://feeds.npr.org/1013/rss.xml', 'rss', 'education', 'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (16, 'NPR History 历史',     'https://feeds.npr.org/1136/rss.xml', 'rss', 'history',   'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (17, 'NPR Law 法律',         'https://feeds.npr.org/1070/rss.xml', 'rss', 'law',       'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (18, 'NPR Family 家庭',      'https://feeds.npr.org/1164/rss.xml', 'rss', 'family',    'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (19, 'NPR Religion 宗教',    'https://feeds.npr.org/1016/rss.xml', 'rss', 'culture',   'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (20, 'NPR Architecture 建筑','https://feeds.npr.org/1142/rss.xml', 'rss', 'culture',   'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (21, 'NPR Weather 天气',     'https://feeds.npr.org/1165/rss.xml', 'rss', 'science',   'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (22, 'NPR Strange News 趣闻','https://feeds.npr.org/1146/rss.xml', 'rss', 'news',      'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (23, 'NPR On Aging 老龄',    'https://feeds.npr.org/1028/rss.xml', 'rss', 'health',    'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    (24, 'NPR Media 媒体',       'https://feeds.npr.org/1020/rss.xml', 'rss', 'news',      'B2', 'news', 1, 0, 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
ON CONFLICT DO NOTHING;

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
    //
    // 🔑 **2026-10-02 起拆成 4 段**（原为一条 `CONTENT_SCHEMA_SQL`）——
    //    因为「重建 `content_source`」必须**复用同一份建表 DDL**，
    //    而重建对「建表 / 建索引」的**顺序**有硬要求（见 `CONTENT_SOURCE_INDEX_SQL` 的说明）。
    conn.execute_batch(CONTENT_SOURCE_TABLE_SQL)
        .map_err(|e| format!("content source table: {}", e))?;
    conn.execute_batch(CONTENT_SOURCE_INDEX_SQL)
        .map_err(|e| format!("content source index: {}", e))?;
    conn.execute_batch(CONTENT_POOL_SQL)
        .map_err(|e| format!("content pool: {}", e))?;
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

    // ── 🆕 内容源种子（**必须在迁移之后**）──
    //
    // 🔴 顺序不能反：`content_source` 的 CHECK 可能在迁移里被**重建更新**
    //    （如 2026-10-02 从 8 类扩到 12 类）。若 seed 先跑，新分类的行会撞上**旧 CHECK**
    //    而**报错**（`ON CONFLICT DO NOTHING` **不忽略** CHECK 违规 —— 这正是我们要的语义，
    //    但也意味着「顺序错了就会炸」）。
    // 📌 判据：**「先保证结构正确，再灌数据」** —— 迁移属于「结构」，seed 属于「数据」。
    conn.execute_batch(CONTENT_SEED_SQL)
        .map_err(|e| format!("content seed: {}", e))?;

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
        // 新库走 `CONTENT_POOL_SQL` 已含此列 → 这里对它们报 `duplicate column` → 容错放行。
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

    // ── 🆕 2026-10-02：让**已存在的**库也拿到 `content_source.category` 的 CHECK ──
    //    （`CREATE TABLE IF NOT EXISTS` 对旧表无效，而 SQLite 不能 ALTER 加 CHECK
    //      ⇒ 唯一的办法是**重建表**。详见函数内的说明。）
    rebuild_content_source_with_check(conn)?;

    Ok(())
}

/// 读出 `content_source` 的 CHECK 里列了哪些分类。
///
/// · 表不存在 → `Ok(None)`（例：`run_migrations()` 被单独调用时还没建表）
/// · 表存在但**没有** CHECK → `Ok(Some(空集))` —— 空集 ≠ 词表 ⇒ 会触发重建
///
/// # 🔑 为什么读 DDL 而不是读源文件
///
/// 因为要判的是「**库里实际生效的约束**」：`CONTENT_SOURCE_TABLE_SQL` 里的 CHECK
/// 对已存在的表**不生效**（`IF NOT EXISTS` 跳过）。读源文件会得到**错的答案**。
/// 📌 判据：**断言/判断要读「生效的东西」**。
///
/// ⚠️ 本函数**同时被迁移（判断是否重建）与测试断言使用** —— 刻意复用同一份解析逻辑，
///    否则「是否要重建」与「重建后是否合格」两处口径会漂移。
fn content_source_check_categories(
    conn: &rusqlite::Connection,
) -> Result<Option<std::collections::BTreeSet<String>>, String> {
    use rusqlite::OptionalExtension;
    let ddl: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='content_source'",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| format!("读 content_source 的 DDL 失败: {}", e))?;

    let Some(ddl) = ddl else { return Ok(None) };

    let Some(seg) = ddl.split("CHECK (category IN (").nth(1) else {
        // 表在，但没写 CHECK（这正是生产库当前的状态 —— CHECK 是后来才加的）
        return Ok(Some(std::collections::BTreeSet::new()));
    };
    let Some(list) = seg.split(')').next() else {
        return Ok(Some(std::collections::BTreeSet::new()));
    };
    Ok(Some(
        list.split(',')
            .map(|x| x.trim().trim_matches('\'').to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    ))
}

/// 🔴 让**已存在的**旧库也获得 `content_source.category` 的 CHECK 约束。
///
/// # 为什么必须「重建表」
///
/// `CREATE TABLE IF NOT EXISTS` **见到表就跳过**（不比对结构），而 SQLite
/// **不支持 `ALTER TABLE ADD CONSTRAINT`** ⇒ 给旧表补 CHECK 的唯一办法是
/// 「建新表 → 拷数据 → 换名」。
///
/// # 收益（配合 seed 的改动才成立）
///
/// 本轮同时把 seed 从 `INSERT OR IGNORE` 改成 `ON CONFLICT DO NOTHING` ——
/// 后者**只忽略重复**，**不忽略 CHECK 违规**。两者合起来才是：
/// **新源写错分类 → 立刻报错**，而不是「静默少一个源、靠数量断言事后发现」。
/// ⚠️ 只做重建不改 seed 的话，收益有限（`OR IGNORE` 照样吞 CHECK 违规）。
///
/// # 幂等
///
/// 判据 = 「DDL 里的类别集合 **≡** `CONTENT_CATEGORIES`」⇒ 相同就跳过。
/// ⇒ 重复执行安全；且**将来再改词表会自动再重建一次**。
///
/// # 🔴 外键（最容易出事的地方）
///
/// `content_pool.source_id REFERENCES content_source(id)`，而连接的
/// `PRAGMA foreign_keys = ON`（`db_pool.rs`）⇒ `DROP TABLE content_source`
/// 会因为外键检查**直接失败**。所以：
/// 1. 必须先 `PRAGMA foreign_keys = OFF`
/// 2. ⚠️ SQLite 规定该 PRAGMA **在事务内是 no-op** ⇒ 必须设在 `BEGIN` **之前**
/// 3. 🔴 **无论成败都要恢复 ON** —— 否则那条池连接会**永久**不校验外键
///    （连接池会复用它，故障是静默的）
fn rebuild_content_source_with_check(conn: &rusqlite::Connection) -> Result<(), String> {
    let Some(have) = content_source_check_categories(conn)? else {
        return Ok(()); // 表还不存在（如 run_migrations 单独调用）→ 无事可做
    };
    let want: std::collections::BTreeSet<String> =
        CONTENT_CATEGORIES.iter().map(|s| s.to_string()).collect();
    if have == want {
        return Ok(()); // 已经是最新结构 → 跳过（幂等）
    }

    conn.execute_batch("PRAGMA foreign_keys = OFF")
        .map_err(|e| format!("重建前关闭外键失败: {}", e))?;

    let outcome = rebuild_content_source_body(conn);

    // 🔴 恢复外键 —— 必须无条件执行
    let restore = conn
        .execute_batch("PRAGMA foreign_keys = ON")
        .map_err(|e| format!("重建后恢复外键失败: {}", e));

    match (outcome, restore) {
        (Err(e), _) => Err(e),
        (Ok(()), Err(e)) => Err(format!(
            "重建成功，但**恢复外键失败** —— 那条连接将不再校验外键（需重启服务）: {}",
            e
        )),
        (Ok(()), Ok(())) => Ok(()),
    }
}

/// `rebuild_content_source_with_check` 的实际动作（把「恢复外键」留给调用方，保证必达）。
fn rebuild_content_source_body(conn: &rusqlite::Connection) -> Result<(), String> {
    const TABLE: &str = "content_source";
    const NEW: &str = "content_source_rebuild";

    // 新表 DDL —— **复用** `CONTENT_SOURCE_TABLE_SQL`（唯一权威），只换表名。
    // ⚠️ 若将来有人改了那句的写法，替换会失败 ⇒ 下面的检查**显式报错**（不静默）。
    let new_ddl = CONTENT_SOURCE_TABLE_SQL.replace(
        &format!("CREATE TABLE IF NOT EXISTS {} (", TABLE),
        &format!("CREATE TABLE {} (", NEW),
    );
    if !new_ddl.contains(&format!("CREATE TABLE {} (", NEW)) {
        return Err(format!(
            "🔴 重建 DDL 的表名替换失败 —— `CONTENT_SOURCE_TABLE_SQL` 的写法变了？\
             期望其中含 `CREATE TABLE IF NOT EXISTS {} (`。",
            TABLE
        ));
    }

    // 重建前先记录「悬空引用」的基线 —— 重建后**不得变多**（既有问题不算重建的错）
    let dangling_before = dangling_pool_refs(conn)?;

    conn.execute_batch("BEGIN IMMEDIATE")
        .map_err(|e| format!("重建开启事务失败: {}", e))?;

    let body = (|| -> Result<(), String> {
        conn.execute_batch(&new_ddl)
            .map_err(|e| format!("建新表失败: {}", e))?;

        // 逐列显式拷贝（**不用 `SELECT *`**）—— 列名写错会直接报错，不会静默错位
        const COLS: &str = "id, name, url, kind, category, cefr_hint, license, \
             redistributable, tz_offset_min, fetch_interval_min, enabled, last_fetch_at, \
             fail_count, created_at, updated_at";
        conn.execute_batch(&format!(
            "INSERT INTO {new} ({cols}) SELECT {cols} FROM {table}",
            new = NEW,
            cols = COLS,
            table = TABLE
        ))
        .map_err(|e| format!("拷贝数据失败: {}", e))?;

        // 🔴 拷贝完整性：行数必须一致（「数字对上」是必要条件；内容比对见测试）
        let old_n = table_row_count(conn, TABLE)?;
        let new_n = table_row_count(conn, NEW)?;
        if old_n != new_n {
            return Err(format!(
                "🔴 重建拷贝行数不符：`{}` {} 行 → 新表 {} 行（**已回滚**）",
                TABLE, old_n, new_n
            ));
        }

        conn.execute_batch(&format!("DROP TABLE {}", TABLE))
            .map_err(|e| format!("删旧表失败: {}", e))?;
        conn.execute_batch(&format!("ALTER TABLE {} RENAME TO {}", NEW, TABLE))
            .map_err(|e| format!("新表改名失败: {}", e))?;

        // 🔑 索引**必须在这里**建（不能在 `new_ddl` 里）：
        //    旧表刚被 DROP 时它的同名索引才消失；在那之前 `CREATE INDEX IF NOT EXISTS`
        //    会因**名字被占**而静默跳过 ⇒ 新表没有唯一索引。
        conn.execute_batch(CONTENT_SOURCE_INDEX_SQL)
            .map_err(|e| format!("重建索引失败: {}", e))?;

        // 🔴 外键完整性：重建后悬空引用不得比基线多
        let dangling_after = dangling_pool_refs(conn)?;
        if dangling_after > dangling_before {
            return Err(format!(
                "🔴 重建后 `content_pool.source_id` 的悬空引用变多（{} → {}），**已回滚**",
                dangling_before, dangling_after
            ));
        }

        Ok(())
    })();

    match body {
        Ok(()) => conn
            .execute_batch("COMMIT")
            .map_err(|e| format!("重建提交失败: {}", e)),
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            Err(format!("{}（事务已回滚，旧表未受影响）", e))
        }
    }
}

/// 表行数（表名来自本模块常量，无注入风险）。
fn table_row_count(conn: &rusqlite::Connection, table: &str) -> Result<i64, String> {
    conn.query_row(&format!("SELECT COUNT(*) FROM {}", table), [], |r| r.get(0))
        .map_err(|e| format!("统计 {} 行数失败: {}", table, e))
}

/// `content_pool.source_id` 指向不存在的源的条数（悬空引用）。
///
/// 🔑 刻意**只查这一条关系**，而不用 `PRAGMA foreign_key_check`
/// （后者返回**整个库**的违规，库里若本来就有别的历史问题会误报成本次重建的错）。
fn dangling_pool_refs(conn: &rusqlite::Connection) -> Result<i64, String> {
    conn.query_row(
        "SELECT COUNT(*) FROM content_pool p \
         LEFT JOIN content_source s ON p.source_id = s.id \
         WHERE p.source_id IS NOT NULL AND s.id IS NULL",
        [],
        |r| r.get(0),
    )
    .map_err(|e| format!("检查 content_pool 悬空引用失败: {}", e))
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
        //    后者设计未定（「兴趣怎么影响排序」还没做）。见 `CONTENT_POOL_SQL`。
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
                "🔴 `{}` 不该存在 —— 见 CONTENT_POOL_SQL 的说明（学习状态已迁端侧）",
                t
            );
        }

        // 种子源：实测**可达**的 23 个（VOA/BBC/Wikipedia 因国内不可达**不在内**）
        //
        // 🔑 **与 `content_fetch::tests::test_seed_sources_are_loaded` 的分工**：
        //    那条数的是 `load_enabled_sources()` 的结果（**启用数** = 23，Ars 被禁用）；
        //    本条数的是**表里的总行数**（**24**，含被禁用的 Ars）。
        //    ⇒ 两者**必须成对更新**（改一处不改另一处，会有一条红）。
        //    📌 这正落实「**同一件事的口径只能有一处权威**」的反面教训：
        //       数字被两处锁着时，要把「两处各是什么口径」写清楚，
        //       否则下一个人只改一处，就会以为是「另一个 bug」。
        //    ⚠️ **2026-10-02 二轮更正**：本注释原写「启用 12 / 总行 13」，
        //       而 `content_fetch` 的断言当时是 **11 / 12** —— **基数差了 1**。
        //       （「总行 = 启用 + 1（禁用 的 Ars）」这层关系是对的，起点写错。）
        //       ⇒ 教训：**加源时必须两边同时核**，只改一边会留下一份错的说明。
        //
        // 🔴 **本断言是「`INSERT OR IGNORE` 吞掉 CHECK 违规」的唯一哨兵** ——
        //    若新源的 category 没同步进 `CHECK (...)`，插入会被**静默**忽略，
        //    表里就会少行 ⇒ 只有这一条会红。（`ensure_schema` 不报错。）
        let seeded: i64 = conn
            .query_row("SELECT COUNT(*) FROM content_source", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            seeded, 24,
            "种子源应为 24 行（5 原有 + 7 首轮 + 2 二轮 + 10 三轮；含被禁用的 Ars —— 禁用≠删除）"
        );

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

    /// 🆕 2026-10-02：**受控词表 ≡ `content_source` 的 CHECK**（**集合相等**）。
    ///
    /// # 🔴 它守的是什么（曾经是一条全程无报错的失效链）
    ///
    ///   ① `CREATE TABLE IF NOT EXISTS` **不重建已存在的表** ⇒ CHECK 改动对旧库无效
    ///   ② `INSERT OR IGNORE` 会**静默吞掉** CHECK 违规（不只重复冲突）
    ///   ③ ⇒「词表加了类、CHECK 没加」= **静默丢源**，只有数量断言会红
    ///      —— 而它只说「少了一行」，**不告诉你是哪个类 / 为什么**。
    ///
    /// ✅ **①② 已于 2026-10-02 修复**：
    ///    · `rebuild_content_source_with_check()` —— 让**已存在的库**也拿到最新 CHECK
    ///    · seed 改 `ON CONFLICT DO NOTHING` —— 只忽略重复，**CHECK 违规会正常报错**
    ///
    /// ⚠️ **但本断言必须保留** —— 它挡的是**新库**这条路径：
    ///    改了 `CONTENT_CATEGORIES` 却漏改建表语句里的 CHECK 时，
    ///    新库照旧会拒收该类的源（`CREATE TABLE` 失败或插入违规）。
    ///    📌 守门人不能因为「另一条路修好了」就撤掉。
    ///
    /// 📌 判据：断言要读「**生效的东西**」（`sqlite_master` 里的 DDL），
    ///    而不是源文件里的声明 —— 并**复用迁移用的同一个解析函数**，
    ///    避免「判断是否重建」与「断言是否合格」两处解析逻辑漂移。
    ///
    /// ⚠️ **独立成 test 而不是塞进 `test_core_table_columns`** ——
    ///    因为后者的数量断言会先 panic，**本条根本没机会跑**
    ///    （实测：删掉 CHECK 里的 `education` 后，只看到「少了一行」）。
    #[test]
    fn test_content_source_check_matches_categories() {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        let in_check = content_source_check_categories(&conn)
            .expect("读 content_source 的 DDL 失败")
            .expect("content_source 表应存在");
        let want: std::collections::BTreeSet<String> =
            CONTENT_CATEGORIES.iter().map(|s| s.to_string()).collect();

        assert_eq!(
            in_check, want,
            "🔴 CHECK 必须与 `CONTENT_CATEGORIES` **集合相等**\
             （左 = DDL 里实际生效的；右 = 词表）。\
             缺一个 ⇒ 该类的新源会被 CHECK 拒绝；多一个 ⇒ 是已删类的残留。"
        );
    }

    /// 🔴🔴 **重建演练**：**旧结构**（`content_source` 无 CHECK）的库跑 `init_database` 后，
    /// 必须拿到最新 CHECK，且**数据一行不丢**、`content_pool` 引用完好、外键已恢复、可重跑。
    ///
    /// # 为什么必须造「旧库」而不是用 `init_database` 建初始状态
    ///
    /// `init_database` 建出来的是**已经是新结构**的库（CHECK 就在建表语句里）⇒
    /// 重建逻辑**根本不会执行**，等于测了个空。
    /// 📌 判据：**想验迁移，就必须造出「迁移前」的状态**
    ///    （同 `test_migrate_from_legacy_users_table` 的做法）。
    ///
    /// # 🔴 为什么显式 `PRAGMA foreign_keys = ON`
    ///
    /// 生产连接的 `foreign_keys` 是 **ON**（`db_pool.rs` 建连接时设），
    /// 而 `open_in_memory()` 默认是 **OFF**。
    /// 若不显式打开，「`DROP TABLE` 被外键挡住」这个**最危险的点**
    /// 在测试里**根本不会暴露** ⇒ 「测试全绿但生产起不来」。
    /// 📌 判据：**测试环境必须与生产一致**（同族：按用户怎么打开来验）。
    ///
    /// # 用**手工源（id=99）**当「数据没丢」的证据
    ///
    /// 它在 seed 里**不存在** ⇒ 若重建把它弄丢，**没有任何 seed 会把它补回来**
    /// （对照：id=1 丢了也会被 seed 重插，掩盖问题）。
    /// 那个源还带 `fail_count = 7` / `last_fetch_at = NULL` —— 顺带验运行时状态。
    #[test]
    fn test_rebuild_content_source_gains_check_and_keeps_data() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();

        // ── ① 造「旧结构」：`content_source` **没有** CHECK（= 生产库当前状态）──
        conn.execute_batch(
            "CREATE TABLE content_source (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                name               TEXT    NOT NULL,
                url                TEXT    NOT NULL,
                kind               TEXT    NOT NULL DEFAULT 'rss',
                category           TEXT,
                cefr_hint          TEXT,
                license            TEXT,
                redistributable    INTEGER NOT NULL DEFAULT 0 CHECK (redistributable IN (0,1)),
                tz_offset_min      INTEGER NOT NULL DEFAULT 0,
                fetch_interval_min INTEGER NOT NULL DEFAULT 360,
                enabled            INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
                last_fetch_at      TEXT,
                fail_count         INTEGER NOT NULL DEFAULT 0,
                created_at         TEXT    NOT NULL,
                updated_at         TEXT    NOT NULL
            );
            CREATE UNIQUE INDEX idx_csrc_url ON content_source (url);",
        )
        .unwrap();
        // `content_pool` 用**真实 DDL** 建 —— 它带 `REFERENCES content_source(id)`，
        // 正是本次要验的那条外键关系。
        conn.execute_batch(CONTENT_POOL_SQL).unwrap();

        // ── ② 塞数据（含 seed 里没有的手工源 + 运行时状态）──
        conn.execute_batch(
            "INSERT INTO content_source (id,name,url,kind,category,cefr_hint,license,
                redistributable,tz_offset_min,fetch_interval_min,enabled,last_fetch_at,
                fail_count,created_at,updated_at) VALUES
             (1,'NPR News','https://feeds.npr.org/1001/rss.xml','rss','news','B2','news',
                1,0,360,1,'2026-10-01T00:00:00Z',0,'C1','U1'),
             (99,'手工加的源','https://example.test/custom.xml','rss','culture','B1','cc',
                0,0,720,0,NULL,7,'C99','U99');
             INSERT INTO content_pool (id,source_id,title,url,fetched_at) VALUES
             (1000,1,'A','https://a.test/1','2026-10-01T00:00:00Z'),
             (1001,99,'B','https://b.test/2','2026-10-01T00:00:00Z');",
        )
        .unwrap();

        assert_eq!(
            content_source_check_categories(&conn).unwrap(),
            Some(std::collections::BTreeSet::new()),
            "前提：旧表应**没有** CHECK（否则测不到重建）"
        );

        // ── ③ 跑真正的初始化路径（内部会触发重建）──
        init_database(&conn).unwrap();

        // ── ④ 拿到最新 CHECK（集合相等）──
        let want: std::collections::BTreeSet<String> =
            CONTENT_CATEGORIES.iter().map(|s| s.to_string()).collect();
        assert_eq!(
            content_source_check_categories(&conn).unwrap().unwrap(),
            want,
            "重建后 CHECK 应等于受控词表"
        );

        // ── ⑤ 🔴 CHECK **真的生效**（这才是重建的目的）──
        let bad = conn.execute(
            "INSERT INTO content_source (name,url,category,created_at,updated_at) \
             VALUES ('x','https://x.test/','bogus','C','U')",
            [],
        );
        assert!(bad.is_err(), "🔴 重建后仍能插入非法分类 —— CHECK 没生效");

        // ── ⑥ 🔴 数据**逐行**完好（不只比行数：「数字对上」≠「成员对上」）──
        let rows: Vec<(i64, String, String, String, Option<String>, i64)> = {
            let mut stmt = conn
                .prepare(
                    "SELECT id,name,category,created_at,last_fetch_at,fail_count \
                     FROM content_source ORDER BY id",
                )
                .unwrap();
            let it = stmt
                .query_map([], |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                    ))
                })
                .unwrap();
            it.map(|x| x.unwrap()).collect()
        };
        let custom = rows
            .iter()
            .find(|r| r.0 == 99)
            .expect("🔴 手工源 id=99 丢了（seed 里没有它，丢了没人补）");
        assert_eq!(custom.1, "手工加的源");
        assert_eq!(custom.2, "culture");
        assert_eq!(custom.3, "C99");
        assert_eq!(custom.4, None, "`last_fetch_at` 应保持 NULL");
        assert_eq!(custom.5, 7, "`fail_count` 应保持 7");

        let npr = rows.iter().find(|r| r.0 == 1).expect("NPR 源丢了");
        assert_eq!(
            npr.4.as_deref(),
            Some("2026-10-01T00:00:00Z"),
            "运行时状态 `last_fetch_at` 丢了"
        );
        assert!(
            rows.iter().any(|r| r.0 == 15),
            "seed 的新源（id 15-24）应已补插"
        );

        // ── ⑦ 🔴 唯一索引仍在（否则 seed 的 `ON CONFLICT(url)` 语义会失效）──
        let dup = conn.execute(
            "INSERT INTO content_source (name,url,category,created_at,updated_at) \
             VALUES ('dup','https://feeds.npr.org/1001/rss.xml','news','C','U')",
            [],
        );
        assert!(dup.is_err(), "🔴 重建后 url 唯一索引没了");

        // ── ⑧ 🔴 `content_pool` 引用完好 + 外键已恢复 ON ──
        assert_eq!(
            dangling_pool_refs(&conn).unwrap(),
            0,
            "重建后 content_pool 出现悬空引用"
        );
        let fk: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
            .unwrap();
        assert_eq!(fk, 1, "🔴 重建后未恢复外键 ON（该连接将永不校验外键）");

        // ── ⑨ 幂等：再跑一遍不报错，且**不该再重建**（DDL 不变）──
        let ddl_before: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='content_source'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        init_database(&conn).unwrap();
        let ddl_after: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='content_source'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(ddl_before, ddl_after, "重复执行应幂等（不该再重建）");
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
