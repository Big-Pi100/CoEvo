//! 账号注销 —— **彻底删除一个用户**
//!
//! 用户自助注销（`/api/user/me/delete`）与管理员硬删（`/api/admin/users/{id}/hard-delete`）
//! **共用本模块** —— 它们是同一件事（彻底删一个用户）。
//!
//! # 🔑 为什么必须共用（而不是各写一份）
//!
//! 管理员硬删原先自带一份删除列表，且**漏了 7+ 张表**（2026-10-04 发现）。
//! 各写一份 ⇒ 两处会**漂**，而漂的后果是**静默留下孤儿数据**
//! （SQLite 的 FK 只管「子表引用不存在的父表」，**管不了「父表删了但子表没清」**）。
//! 📌 判据：**同一件事的口径只能一处权威**。
//!
//! # 🔴 两条合规硬约束（Apple 5.1.1(v) 原文）
//!
//! 1. **「仅停用/禁用账号」不够** ⇒ 必须**真删**（所以软删 `users.deleted_at` 不满足；
//!    那是 `admin_delete_user` 的语义，与「注销」不是一回事）
//! 2. **不得要求用户发邮件/打电话**才能注销 ⇒ 必须 App 内自助完成
//!
//! # 处理策略：**不是「一律删」**（逐表分类）
//!
//! | 类别 | 策略 | 理由 |
//! |---|---|---|
//! | 个人数据（凭据/设置/通知/参与记录）| 🔴 **删** | 无保留义务；删了才算「注销」|
//! | 交易与审计（订单/订阅/IAP/分销）| 🟡 **匿名化** | 法定保存义务 + 平台对账；法律文本已写明「删除**或匿名化**」|
//! | `trial_ip_log` | ⚪ **不动** | **不含用户标识**（只有 IP）；反滥用用途（隐私政策已披露）|
//!
//! # 🔴 为什么必须临时关闭外键（`PRAGMA foreign_keys = OFF`）
//!
//! 生产连接**开了外键**（`db_pool.rs`：`PRAGMA foreign_keys = ON`）。而匿名化要做的
//! 恰恰是**让 `user_id` 指向一个不存在的用户**：
//!
//! ```text
//! UPDATE payment_orders SET user_id = 'deleted:<uuid>' WHERE user_id = ?1
//!                                    ↑ users 表里没有这个 id
//! ```
//!
//! ⚠️ 上一块必须标 `text` —— 不标的话 Rust 会把它当 **doctest 去编译**（`UPDATE ...` 不是 Rust）
//!    ⇒ `cargo test` 的 doctest 阶段失败（本轮实际踩到）。
//! ⇒ 外键开启时**必然报错**（`FOREIGN KEY constraint failed`）。
//! 这不是「绕过校验」，而是**语义上 FK 在这一步不适用** ——
//! 匿名化的定义就是「断开与用户的引用关系」，要求引用有效是自相矛盾的。
//!
//! ⚠️ **`PRAGMA foreign_keys` 在事务内是 no-op**（SQLite 规定）⇒ 必须在 `BEGIN` **之前**关，
//!    在 `COMMIT/ROLLBACK` **之后**开。
//! 🔴 **且必须无条件恢复** —— 那是 **r2d2 连接池**的连接，忘记恢复会让**那条连接**
//!    此后再不校验外键（静默失去保护）。见 `with_foreign_keys_off`。
//!    （同族先例：`schema.rs::rebuild_content_source` 已用同一模式。）

use rusqlite::{params, Connection};

/// 注销模式 —— 决定「是否写运维归档」。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PurgeMode {
    /// 用户自助注销：**不写任何含 PII 的归档**（用户已要求删除，不该在磁盘再留一份）。
    SelfService,
    /// 管理员硬删：写 `data/deleted_users.ndjson`（运维需要可辨识记录 —— 见该分支注释）。
    AdminArchive,
}

impl PurgeMode {
    fn audit_action(self) -> &'static str {
        match self {
            PurgeMode::SelfService => "self_delete_user",
            PurgeMode::AdminArchive => "hard_delete_user",
        }
    }
}

/// 一次清理的结果（供调用方/测试观察）。
#[derive(Debug, Default)]
pub struct PurgeReport {
    /// 该用户此前是否存在。`false` ⇒ 幂等命中（已注销过），**不算失败**。
    pub user_existed: bool,
    /// 匿名化访问：`(表名, 影响行数)`
    pub anonymized: Vec<(&'static str, usize)>,
    /// 删除访达：`(表名, 影响行数)`
    pub deleted: Vec<(&'static str, usize)>,
    /// 本次使用的匿名 id（审计用）
    pub anon_id: String,
}

impl PurgeReport {
    pub fn anonymized_rows(&self) -> usize {
        self.anonymized.iter().map(|(_, n)| n).sum()
    }
    pub fn deleted_rows(&self) -> usize {
        self.deleted.iter().map(|(_, n)| n).sum()
    }
}

/// 🔴 **匿名化清单**：`(表名, 关联用户的列)` —— 保留记录，但断开与用户的引用。
///
/// ⚠️ 这些**不是**「含 `user_id` 的表」—— 分销表用了**换名列**。
///    只按 `user_id` grep 会漏掉 4 张表（`tests::purge_covers_all_user_refs` 守着这一点）。
pub const ANONYMIZE_TARGETS: &[(&str, &str)] = &[
    ("payment_orders", "user_id"),
    ("iap_transactions", "user_id"),
    ("subscription_audit_log", "target_user_id"),
    ("admin_audit_log", "target_user_id"),
    ("reward_fulfillments", "user_id"),
    ("referral_clicks", "referrer_id"),
    // ⚠️ 分销佣金表有**两个**指向用户的列 —— 都要处理
    ("distribution_commissions", "earner_id"),
    ("distribution_commissions", "buyer_id"),
    ("distribution_expenses", "earner_id"),
    // 🔴 `users.referred_by` —— **别人行里的引用**，容易漏。
    //
    //    「u2 由 u1 推荐」⇒ `u2.referred_by = 'u1'`。注销 u1 时：
    //    · 只看 `users` 要被**删除**，容易忽略「别人的行里还记着 u1」
    //    · 漏了它 ⇒ 注销后仍能从 u2 反查到 u1（**匿名化不彻底**）
    //    ⚠️ 本表同时在 `DELETE_TARGETS` 里（删 u1 自己的行）——
    //       同一张表「既匿名化又删除」是**有意**的：匿名化处理**别人的行**，删除处理**自己的行**。
    ("users", "referred_by"),
];

/// 🔴 **删除清单**：个人数据（无保留义务）。
///
/// ⚠️ `users` **必须最后**（它是被引用方）。虽然本次在 FK OFF 下执行，
///    但保持「先子后父」的顺序能让代码在 FK ON 的语境下也读得通
///    （防止将来有人「顺手」把 FK OFF 去掉）。
pub const DELETE_TARGETS: &[(&str, &str)] = &[
    ("tokens", "user_id"),
    // 🆕 2026-10-05：找回密码的验证码 —— 纯个人数据（无保留义务）⇒ **删除**，不匿名化。
    //    🔴 为什么是删而不是匿名化：它的内容就是「重置密码的凭据」，
    //       行本身对业务没有任何留存价值（与支付流水不同 —— 那些要留给对账）。
    ("password_reset", "user_id"),
    // 🆕 2026-10-07：修改邮箱的验证码 —— 与 `password_reset` 同理 ⇒ **删除**，不匿名化。
    //    🔴 为什么是删：它的内容就是「换绑邮箱的凭据」，行本身对业务无留存价值。
    //    ⚠️ 漏了它 ⇒ 注销后库里还留着「这个账号想换到哪个邮箱」的痕迹
    //       （**匿名化不彻底**：旧邮箱与新邮箱的关联仍可反查）。
    ("email_change", "user_id"),
    ("user_preferences", "user_id"),
    ("user_notifications", "user_id"),
    ("subscription_requests", "target_user_id"),
    ("campaign_members", "user_id"),
    // 🆕 2026-10-06：云端同步副本（订阅权益）—— **删除**，不匿名化。
    //    🔴 为什么是删：这 5 张表**整体都是用户的学习数据**（复习事件 / 生词本 /
    //       阅读记录 / 收藏 / 电子书进度）⇒ 它们**没有「非个人用途」**，
    //       不像支付流水那样需要留给对账 ⇒ 匿名化无从下手（匿名化了剩下的列也没意义）。
    //    🔑 与 `password_reset` 同一判断：**行本身对业务没有留存价值** ⇒ 删。
    //    ⚠️ 隐私政策 §2.1 已写明「注销账号时一并删除」—— 漏了这几张表就是**政策失实**。
    ("sync_review_log", "user_id"),
    ("sync_user_word", "user_id"),
    ("sync_article_read", "user_id"),
    ("sync_bookmark", "user_id"),
    ("sync_book_progress", "user_id"),
    // ⚠️ 最后
    ("users", "id"),
];

/// 在「外键关闭」的上下文中执行 `body`，**并无论如何恢复外键**。
///
/// # 🔴 为什么必须无条件恢复
///
/// `PRAGMA foreign_keys` 是**连接级**设置。这里的 `conn` 来自 **r2d2 连接池**
/// ⇒ 它会**被后续请求复用**。若某条路径忘了恢复，那条连接此后
/// **静默地不再校验外键** —— 表现为「本该被拦住的坏数据悄悄写进去了」，
/// 而且**不会有任何报错**（本项目最警惕的「静默失效」）。
///
/// ⚠️ 恢复失败时**明确报错**（而不是当作成功）—— 因为那意味着那条连接已失去保护，
///    需要人工介入（重启服务）。同族先例：`schema.rs::rebuild_content_source`。
fn with_foreign_keys_off<T>(
    conn: &Connection,
    body: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    // ⚠️ 必须在 BEGIN 之前 —— 事务内改 `foreign_keys` 是 no-op（SQLite 规定）
    conn.execute_batch("PRAGMA foreign_keys = OFF")
        .map_err(|e| format!("注销前关闭外键失败: {}", e))?;

    let outcome = body();

    let restore = conn
        .execute_batch("PRAGMA foreign_keys = ON")
        .map_err(|e| format!("注销后恢复外键失败: {}", e));

    match (outcome, restore) {
        (Err(e), _) => Err(e),
        (Ok(_), Err(e)) => Err(format!(
            "注销已完成，但**恢复外键失败** —— 那条连接将不再校验外键（需重启服务）: {}",
            e
        )),
        (Ok(v), Ok(())) => Ok(v),
    }
}

/// 主入口：彻底删除用户 `uid`。
///
/// - **幂等**：用户不存在 ⇒ 返回 `Ok`（`user_existed=false`），不报错
/// - **事务**：全部成功才提交；任一失败 `ROLLBACK`（不留半删状态）
pub fn purge_user(
    conn: &Connection,
    uid: &str,
    mode: PurgeMode,
    actor: &str,
) -> Result<PurgeReport, String> {
    purge_user_with_archive(
        conn,
        uid,
        mode,
        actor,
        &std::path::Path::new("data").join("deleted_users.ndjson"),
    )
}

/// 同 [`purge_user`]，但**归档路径可注入**。
///
/// 🔑 存在的唯一理由：**让「归档行为」可被行为断言测到**。
///    路径写死的话，测试要么污染仓库的 `data/`、要么只能去做**源码字面量断言**
///    （那种断言既脆弱、又会因测试代码自身含同样字符串而**假绿**）。
///    📌 判据：**能改的（路径）就参数化，别用「扫描源码」代替行为验证**。
pub fn purge_user_with_archive(
    conn: &Connection,
    uid: &str,
    mode: PurgeMode,
    actor: &str,
    archive_path: &std::path::Path,
) -> Result<PurgeReport, String> {
    // 🔴 AdminArchive 必须**在删除前**取快照 —— 删除后 `users` 行就没了，
    //    再查 username/email 只会得到 None（初版就这么错了：注释还辩解「查不到是正常的」，
    //    那是把 bug 写成设计说明 —— **注释不能替代正确性**）。
    let snapshot = if mode == PurgeMode::AdminArchive {
        archive_snapshot(conn, uid)
    } else {
        None
    };

    let report = with_foreign_keys_off(conn, || purge_user_tx(conn, uid, mode, actor))?;

    // 仅在**真的删掉了**的时候写归档（幂等命中时没什么可归档的）
    if let Some(snap) = snapshot {
        if report.user_existed {
            write_admin_archive(&snap, actor, archive_path);
        }
    }

    Ok(report)
}

/// 抓取管理员归档所需的快照（**必须在 purge 之前调用**）。
fn archive_snapshot(conn: &Connection, uid: &str) -> Option<serde_json::Value> {
    conn.query_row(
        "SELECT u.username, u.display_name, u.email, u.subscription_expires, u.created_at,
                up.value
         FROM users u
         LEFT JOIN user_preferences up ON u.id = up.user_id AND up.key = 'subscription_activated_at'
         WHERE u.id = ?1",
        params![uid],
        |r| {
            Ok(serde_json::json!({
                "original_user_id": uid,
                "username": r.get::<_, String>(0)?,
                "display_name": r.get::<_, Option<String>>(1)?,
                "email": r.get::<_, Option<String>>(2)?,
                "subscription_expires": r.get::<_, Option<String>>(3)?,
                "user_created_at": r.get::<_, Option<String>>(4)?,
                "subscription_activated_at": r.get::<_, Option<String>>(5)?,
            }))
        },
    )
    .ok()
}

/// 事务内的清理主体（调用方保证已在 FK OFF 下）。
fn purge_user_tx(
    conn: &Connection,
    uid: &str,
    mode: PurgeMode,
    actor: &str,
) -> Result<PurgeReport, String> {
    let mut report = PurgeReport {
        // 🔑 每个表共用一个匿名 id（而不是每表一个）——
        //    这样「同一匿名用户的多笔交易」在数据上仍**内部一致**，便于日后对账。
        anon_id: format!("deleted:{}", uuid::Uuid::new_v4()),
        ..Default::default()
    };

    // ── 0. 幂等检查：用户不存在 ⇒ 直接成功（已注销过）──
    let exists = conn
        .query_row(
            "SELECT 1 FROM users WHERE id = ?1",
            params![uid],
            |_| Ok(()),
        )
        .is_ok();
    if !exists {
        return Ok(report); // user_existed 保持 false
    }
    report.user_existed = true;

    // ── 1. 事务开始 ──
    conn.execute_batch("BEGIN IMMEDIATE")
        .map_err(|e| format!("开启事务失败: {}", e))?;

    // 用一个内部闭包承载「所有步骤」，便于统一 ROLLBACK
    // ⚠️ 必须 `mut`：闭包内会 `push` 到 `report`（可变借用）
    let mut body = || -> Result<(), String> {
        // ── 2. 匿名化（保留记录，断开引用）──
        for (table, col) in ANONYMIZE_TARGETS {
            let sql = format!("UPDATE {} SET {} = ?2 WHERE {} = ?1", table, col, col);
            let n = conn
                .execute(&sql, params![uid, report.anon_id])
                .map_err(|e| format!("匿名化 {}.{} 失败: {}", table, col, e))?;
            report.anonymized.push((table, n));
        }

        // ── 3. 删除个人数据 ──
        for (table, col) in DELETE_TARGETS {
            let sql = format!("DELETE FROM {} WHERE {} = ?1", table, col);
            let n = conn
                .execute(&sql, params![uid])
                .map_err(|e| format!("删除 {} 失败: {}", table, e))?;
            report.deleted.push((table, n));
        }

        // ── 4. 审计留痕 ──
        //
        // 🔴 `target_user_id` 用**匿名 id**（不是原 uid）——
        //    否则审计表本身就成了「注销后仍可反查身份」的漏洞。
        //    🔑 我们只需要「某账号在某时被注销了」这个事实，不需要它是谁。
        let now = chrono::Utc::now().timestamp().to_string();
        conn.execute(
            "INSERT INTO admin_audit_log (id, admin_id, action, target_user_id, request_id, detail, created_at)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6)",
            params![
                uuid::Uuid::new_v4().to_string(),
                actor,
                mode.audit_action(),
                report.anon_id,
                serde_json::json!({
                    "anonymized_rows": report.anonymized_rows(),
                    "deleted_rows": report.deleted_rows(),
                    "mode": match mode {
                        PurgeMode::SelfService => "self_service",
                        PurgeMode::AdminArchive => "admin_archive",
                    },
                })
                .to_string(),
                now,
            ],
        )
        .map_err(|e| format!("写审计日志失败: {}", e))?;

        Ok(())
    };

    match body() {
        Ok(()) => {
            conn.execute_batch("COMMIT")
                .map_err(|e| format!("提交事务失败: {}", e))?;
        }
        Err(e) => {
            // 🔴 回滚失败也要报出来（连接可能处于事务中，后续操作会异常）
            if let Err(re) = conn.execute_batch("ROLLBACK") {
                return Err(format!("{}；且 ROLLBACK 失败: {}", e, re));
            }
            return Err(e);
        }
    }

    // 注：管理员归档**不在这里写** —— 它需要删除**之前**的快照，
    //     故由 `purge_user` 负责（见那里的说明）。

    tracing::info!(
        "用户注销完成 uid={} mode={:?} 匿名 {} 行 / 删除 {} 行",
        uid,
        mode,
        report.anonymized_rows(),
        report.deleted_rows()
    );

    Ok(report)
}

/// 管理员硬删的运维归档（`data/deleted_users.ndjson`）。
///
/// # 🔴 2026-10-04 修的三个问题
///
/// **① 归档被覆盖**：原实现用 `std::fs::write`，它是**截断覆盖** ⇒
///    第二次硬删会把第一次的归档**冲掉**（注释却写着「归档记录写入」）。
///    ⇒ 改用 **append**。
///
/// **② 归档时机错**：初版在 purge **之后**取 username/email ⇒
///    `users` 行已删，只能拿到 None。**注释还辩解「查不到是正常的」** ——
///    那是把 bug 写成设计说明。📌 **注释不能替代正确性**。
///    ⇒ 改为接收「purge 前抓取的快照」（见 `archive_snapshot`）。
///
/// **③ PII 边界**：归档含 `email` **明文**。原注释说这是有意放宽
///    （运维需要可辨识度 —— `phone_hash` 那种「存哈希只为让运维也认不出」的做法
///    在改邮箱后毫无辨识度）。
///    ✅ 该理由对**管理员硬删**成立，故保留 email ——
///    但**仅限这条路径**：用户自助注销**不经此函数**（用户已要求删除，
///    再在磁盘留一份含 email 的副本与注销语义直接冲突）。
///
/// ⚠️ 写文件失败**不影响注销结果**（事务已提交）；但必须记日志，
///    否则运维会误以为「归档里没有 = 注销没发生」。
/// ⚠️ 路径**参数化**（而不是写死在函数里）的唯一理由：**可测**。
///    写死的话，测试要么污染仓库的 `data/`、要么只能不测 —— 而「不测」意味着
///    「append 而非覆盖」这条修复**永远不会被验证**（正是本轮踩到的 bug 类型）。
fn write_admin_archive(snapshot: &serde_json::Value, actor: &str, path: &std::path::Path) {
    use std::io::Write as _;

    let mut entry = snapshot.clone();
    if let Some(obj) = entry.as_object_mut() {
        obj.insert("deleted_by".into(), serde_json::json!(actor));
        obj.insert(
            "deleted_at".into(),
            serde_json::json!(chrono::Utc::now().timestamp().to_string()),
        );
        obj.insert(
            "deleted_at_rfc3339".into(),
            serde_json::json!(chrono::Utc::now().to_rfc3339()),
        );
    }

    // ⚠️ 路径来自参数（调用方决定）—— 这里**不要**再 `let path = ...`，
    //    否则会遮蔽参数（初版就这么写错了：签名收了 path，函数体又自己造了一个）。
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    match std::fs::OpenOptions::new()
        .create(true)
        .append(true) // 🔑 append —— 修问题 ①
        .open(path) // `path` 已是 `&Path`，不要再 `&`
    {
        Ok(mut f) => {
            if let Err(e) = writeln!(f, "{}", serde_json::to_string(&entry).unwrap_or_default()) {
                tracing::warn!("写归档文件失败（注销已完成）: {}", e);
            }
        }
        Err(e) => tracing::warn!("打开归档文件失败（注销已完成）: {} path={:?}", e, path),
    }
}
// ══════════════════════════════════════════════════════════════════════════
// Handler：`POST /api/user/me/delete`（用户自助注销）
// ══════════════════════════════════════════════════════════════════════════
//
// 📌 handler 与服务层同文件：本功能**只有一个入口**，为它另开文件只会增加跳转成本。
//    若将来注销相关端点变多（如「撤销注销冷静期」），再拆文件。

use crate::error::AppError;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;

/// 从 `Authorization: Bearer <token>` **反查 uid**。
///
/// # 🔴 为什么不用「客户端传 uid + `verify_auth`」的既有模式
///
/// 既有模式（见 `iap_handlers`）是「body 带 uid，服务端校验它与 token 匹配」——
/// **那个也安全**（token 匹配通过 ⇒ 客户端确实持有该账号的 token）。
/// 但注销是**自操作**：从 token 反查 uid 更直接 ——
/// **调用方在协议上就无法指定「要删谁」**，少一个「客户端参数被篡改」的思量面。
///
/// 📌 两种模式并存是**有意**的：不动存量（`verify_auth` 的既有调用方），
///    新接口用约束更强的那种。
/// 从 `Authorization: Bearer <token>` 头里取出 token —— **全后端唯一实现**。
///
/// 🔑 2026-10-05 抽出：原先只有本模块的 `resolve_uid_from_token` 里有这段解析，
///    而「修改密码」要知道**当前 token 本身**（用于「保留当前会话、失效其他」）
///    ⇒ 若各写一份，两处的 header 名/前缀/错误文案会**静默漂移**。
pub(crate) fn extract_bearer_token(headers: &HeaderMap) -> Result<String, AppError> {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .ok_or_else(|| AppError::Unauthorized("缺少 Authorization 头".to_string()))
}

/// 用会话 token 反查 `user_id`（**唯一实现**，见 `crate::auth::uid_by_token`）。
pub(crate) fn resolve_uid_by_token(token: &str) -> Result<String, AppError> {
    let conn = crate::db_pool::get_conn();
    crate::auth::uid_by_token(&conn, token).map_err(AppError::Unauthorized)
}

fn resolve_uid_from_token(headers: &HeaderMap) -> Result<String, AppError> {
    let token = extract_bearer_token(headers)?;
    resolve_uid_by_token(&token)
}

/// `POST /api/user/me/delete` —— 用户自助注销账号。
///
/// # 🔴 为什么用 POST 而不是 DELETE
///
/// 语义上说 DELETE 更贴切，但注销要做**多步事务**、且客户端（含 iOS 网络栈与
/// 中间代理）对「DELETE 带 body」的支持并不一致。POST 没有这类歧义。
///
/// # 响应
///
/// | 情况 | HTTP | body |
/// |---|---|---|
/// | 删除成功 | 200 | `{"status":"deleted"}` |
/// | **幂等命中**（账号已不存在）| 200 | `{"status":"already_deleted"}` |
/// | 未登录 / token 失效 | 401 | `{"error":...}` |
/// | 服务端失败（已回滚）| 500 | `{"error":...}` |
///
/// 🔑 幂等命中返回 **200 而不是 404**：客户端重试不该被当成错误
///    （用户点了两次「注销」，第二次不该看到红字）。
pub async fn delete_me_handler(headers: HeaderMap) -> impl IntoResponse {
    let uid = match resolve_uid_from_token(&headers) {
        Ok(u) => u,
        Err(e) => return e.into_response(),
    };

    let conn = crate::db_pool::get_conn();
    match purge_user(&conn, &uid, PurgeMode::SelfService, "self") {
        Ok(rep) => {
            let status = if rep.user_existed {
                "deleted"
            } else {
                "already_deleted"
            };
            (
                StatusCode::OK,
                serde_json::json!({ "status": status }).to_string(),
            )
                .into_response()
        }
        Err(e) => {
            // 🔴 事务已回滚 ⇒ 账号**未被删除**。必须让日志能看出这一点，
            //    否则运维看到「注销失败」还得去推断「到底删了没」。
            tracing::error!("自助注销失败（已回滚，账号未删除）uid={}: {}", uid, e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                serde_json::json!({"error": "注销失败，账号未删除，请稍后重试"}).to_string(),
            )
                .into_response()
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════
// 测试
// ══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        // 🔴 与生产一致：`db_pool` 建连接时开外键
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
        conn
    }

    /// 造一个「有各种关联数据」的用户。
    ///
    /// # 🔴 为什么 fixture 阶段临时关外键
    ///
    /// 引用图里有些表的父行**不属本模块的被测对象**（如 `referral_clicks.campaign_id`
    /// 要求先有 `marketing_campaigns` 行）。为它们建完整父子链会让 fixture 与
    /// **多张无关表的结构过度耦合** —— 那些表改一下列，本模块测试就红。
    /// ⇒ fixture 只需「数据存在」，引用完整性不在这一层验证。
    ///
    /// ⚠️ 而 **purge 自身**的 FK 行为仍然被验证：`purge_restores_foreign_keys`。
    ///
    /// ⚠️ 列名必须**照 schema 真实定义**写 —— 初版凭印象写 `user_preferences(user_id,key,value)`
    ///    漏了 NOT NULL 的 `updated_at`，10 个测试全红。📌 **fixture 也是「实现」，要与真实结构对齐**。
    fn seed_user(conn: &Connection, uid: &str) {
        let now = "2026-10-04T00:00:00Z";
        conn.execute_batch("PRAGMA foreign_keys = OFF").unwrap();

        conn.execute(
            "INSERT INTO users (id, username, password_hash, email, created_at)
             VALUES (?1, ?2, 'h', ?3, ?4)",
            params![uid, format!("u_{}", uid), format!("{}@e.com", uid), now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1,?2,?3,?4)",
            params![format!("t_{}", uid), uid, format!("tok_{}", uid), now],
        )
        .unwrap();
        // ⚠️ 真实列：`user_id, key, value, updated_at`（后三个 NOT NULL）
        conn.execute(
            "INSERT INTO user_preferences (user_id, key, value, updated_at) VALUES (?1,'k','v',?2)",
            params![uid, now],
        )
        .unwrap();
        // ⚠️ 真实列含 `notification_type`（NOT NULL）
        conn.execute(
            "INSERT INTO user_notifications (id, user_id, notification_type, title, body, created_at)
             VALUES (?1,?2,'system','t','b',?3)",
            params![format!("n_{}", uid), uid, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO payment_orders (id,user_id,plan_id,amount,status,created_at)
             VALUES (?1,?2,'p',990,'SUCCESS',?3)",
            params![format!("o_{}", uid), uid, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO iap_transactions
               (transaction_id, original_transaction_id, user_id, product_id, created_at, updated_at)
             VALUES (?1,?2,?3,'com.coevo.coevoApp.pro.monthly',?4,?4)",
            params![format!("tx_{}", uid), format!("otx_{}", uid), uid, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO subscription_audit_log (action,target_user_id,new_expires,created_at)
             VALUES ('pay',?1,'2027-01-01',?2)",
            params![uid, now],
        )
        .unwrap();
        // 🔴 换名列：`referrer_id`（不是 user_id）
        conn.execute(
            "INSERT INTO referral_clicks (id,campaign_id,referrer_id,created_at)
             VALUES (?1,'c',?2,?3)",
            params![format!("rc_{}", uid), uid, now],
        )
        .unwrap();

        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
    }

    fn count(conn: &Connection, sql: &str, uid: &str) -> i64 {
        conn.query_row(sql, params![uid], |r| r.get(0)).unwrap()
    }

    // ── 正向：该删的删了 / 该匿名的匿名了 ──

    #[test]
    fn purge_deletes_personal_data() {
        let conn = setup();
        seed_user(&conn, "u1");
        let rep = purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();
        assert!(rep.user_existed);

        for (table, col) in DELETE_TARGETS {
            let n = count(
                &conn,
                &format!("SELECT COUNT(*) FROM {} WHERE {} = ?1", table, col),
                "u1",
            );
            assert_eq!(n, 0, "{} 里仍有已注销用户的行", table);
        }
    }

    #[test]
    fn purge_anonymizes_transactions_not_deletes_them() {
        let conn = setup();
        seed_user(&conn, "u1");
        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        // 🔴 交易记录**必须还在**（法定保存义务）—— 只是不再指向原用户
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM payment_orders", [], |r| r.get(0))
            .unwrap();
        assert_eq!(total, 1, "订单被删了 —— 应保留并匿名化");

        let anon: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM payment_orders WHERE user_id LIKE 'deleted:%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(anon, 1, "订单未被匿名化");
    }

    /// 🔴 **全库不得再出现该 uid** —— 这是「匿名化彻底性」的强断言。
    ///
    /// 逐表逐列扫，比逐一断言可靠（漏了某张表会被这条抓到）。
    #[test]
    fn purge_leaves_no_trace_of_uid_anywhere() {
        let conn = setup();
        seed_user(&conn, "u1");
        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        let tables: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type='table'")
                .unwrap();
            let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
            rows.filter_map(|r| r.ok())
                .filter(|t| !t.starts_with("sqlite_"))
                .collect()
        };

        let mut leaks = Vec::new();
        for t in &tables {
            let cols: Vec<String> = {
                let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", t)).unwrap();
                let rows = stmt.query_map([], |r| r.get::<_, String>(1)).unwrap();
                rows.filter_map(|r| r.ok()).collect()
            };
            for c in cols {
                // 只查文本列（数字列不可能存 uid）
                let sql = format!(
                    "SELECT COUNT(*) FROM {} WHERE CAST({} AS TEXT) = 'u1'",
                    t, c
                );
                if let Ok(n) = conn.query_row(&sql, [], |r| r.get::<_, i64>(0)) {
                    if n > 0 {
                        leaks.push(format!("{}.{}", t, c));
                    }
                }
            }
        }
        assert!(
            leaks.is_empty(),
            "注销后仍在这些位置找到原 uid: {:?}",
            leaks
        );
    }

    // ── 反向：**不该删的不能删** ──

    /// 🔴 `users.referred_by` 是「**别人行里的引用**」—— 最容易漏的一类。
    ///
    /// u2 由 u1 推荐 ⇒ `u2.referred_by = 'u1'`。注销 u1 时：
    /// **`users` 表是被「删除」的**，很容易只想到「删掉 u1 那一行」，
    /// 而忘了「别人行里还记着 u1」⇒ 注销后仍能从 u2 反查到 u1。
    #[test]
    fn purge_anonymizes_referred_by_in_other_users() {
        let conn = setup();
        seed_user(&conn, "u1");
        seed_user(&conn, "u2");
        conn.execute("UPDATE users SET referred_by = 'u1' WHERE id = 'u2'", [])
            .unwrap();

        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        let rb: Option<String> = conn
            .query_row("SELECT referred_by FROM users WHERE id='u2'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(
            rb.as_deref().map_or(true, |v| !v.contains("u1")),
            "u2.referred_by 仍指向已注销的 u1（可从 u2 反查回已注销用户）: {:?}",
            rb
        );
    }

    #[test]
    fn purge_does_not_touch_other_users() {
        let conn = setup();
        seed_user(&conn, "u1");
        seed_user(&conn, "u2");
        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM users WHERE id = ?1", "u2"),
            1
        );
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM tokens WHERE user_id = ?1",
                "u2"
            ),
            1
        );
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM payment_orders WHERE user_id = ?1",
                "u2"
            ),
            1,
            "别人的订单被动了"
        );
    }

    #[test]
    fn purge_does_not_touch_trial_ip_log() {
        let conn = setup();
        seed_user(&conn, "u1");
        conn.execute(
            "INSERT INTO trial_ip_log (ip, created_at) VALUES ('1.2.3.4','2026-10-04')",
            [],
        )
        .unwrap();
        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM trial_ip_log", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "trial_ip_log 不含用户标识，不该被注销影响");
    }

    // ── 幂等 / FK 恢复 / 事务 ──

    #[test]
    fn purge_is_idempotent() {
        let conn = setup();
        seed_user(&conn, "u1");
        assert!(
            purge_user(&conn, "u1", PurgeMode::SelfService, "self")
                .unwrap()
                .user_existed
        );
        // 第二次不应报错
        let r2 = purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();
        assert!(!r2.user_existed, "第二次应报告「用户不存在」而非报错");
    }

    /// 🔴 **外键必须被恢复** —— 连接来自池子，会被复用。
    #[test]
    fn purge_restores_foreign_keys() {
        let conn = setup();
        seed_user(&conn, "u1");
        purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        let fk: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
            .unwrap();
        assert_eq!(fk, 1, "注销后未恢复 foreign_keys=ON ⇒ 该连接失去外键保护");
    }

    /// 🔴 断言**注销列表覆盖了 schema 里所有「关联用户」的列**。
    ///
    /// 这是防「加了新表忘加注销」的**自动防线** ——
    /// 光靠人记得「加表时要同步注销列表」不是防线（本项目判据：约定 ≠ 约束）。
    #[test]
    fn purge_covers_all_user_refs() {
        let schema_src = include_str!("schema.rs");
        // 所有可能指向用户的列名
        //
        // 🔴 `referred_by` 极易漏 —— 它是「**别人行里的引用**」
        //    （u2.referred_by = u1），而 `users` 表整体是被**删除**的，
        //    很容易只想到「删 users 行」而忘了「清别人行里对它的引用」。
        const USER_COLS: &[&str] = &[
            "user_id",
            "target_user_id",
            "referrer_id",
            "earner_id",
            "buyer_id",
            "referred_by",
        ];

        let re_table =
            regex::Regex::new(r"CREATE TABLE IF NOT EXISTS (\w+)\s*\(([^;]*?)\n\s*\)").unwrap();

        let mut missing = Vec::new();
        for cap in re_table.captures_iter(schema_src) {
            let table = cap.get(1).unwrap().as_str();
            let body = cap.get(2).unwrap().as_str();
            for col in USER_COLS {
                // 🔴 必须按「**列定义行**」精确匹配，**不能用 `contains`** ——
                //    `target_user_id` **包含** `user_id` 子串 ⇒ `contains` 会把它
                //    误判成「本表也有 user_id 列」。
                //    📌 本轮就被这条**假红**拦下过：它报了 3 张并不含 `user_id` 的表。
                //    判据：**断言的匹配粒度必须等于它的语义粒度** ——
                //      这里要问的是「有没有这一**列**」，不是「有没有这一段字符」。
                let pat = format!(r"(?m)^\s+{}\s", regex::escape(col));
                let re_col = regex::Regex::new(&pat).unwrap();
                if !re_col.is_match(body) {
                    continue;
                }
                let covered = ANONYMIZE_TARGETS
                    .iter()
                    .chain(DELETE_TARGETS.iter())
                    // ⚠️ 两侧都要解到 `&str`（`col` 来自 `&[&str]` 的迭代 ⇒ 是 `&&str`）
                    .any(|(t, c)| *t == table && *c == *col);
                if !covered {
                    missing.push(format!("{}.{}", table, col));
                }
            }
        }
        assert!(
            missing.is_empty(),
            "这些「关联用户」的列没进注销清单（会留孤儿数据）: {:?}\n\
             ⇒ 请把它们加到 ANONYMIZE_TARGETS（保留记录）或 DELETE_TARGETS（删除）",
            missing
        );
    }

    #[test]
    fn purge_writes_audit_with_anonymized_target() {
        let conn = setup();
        seed_user(&conn, "u1");
        let rep = purge_user(&conn, "u1", PurgeMode::SelfService, "self").unwrap();

        let (action, target): (String, String) = conn
            .query_row(
                "SELECT action, target_user_id FROM admin_audit_log ORDER BY created_at DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(action, "self_delete_user");
        assert_eq!(target, rep.anon_id);
        assert!(target.starts_with("deleted:"), "审计里的 target 必须匿名");
    }

    /// 🔴 **行为断言**：两种模式的归档差异 —— 不是扫源码，而是真的跑一遍看文件。
    ///
    /// | 模式 | 归档文件 |
    /// |---|---|
    /// | `SelfService` | ❌ **不得产生**（用户已要求删除，不该在磁盘留 PII 副本）|
    /// | `AdminArchive` | ✅ 产生，且**追加**（不是覆盖）|
    #[test]
    fn self_service_writes_no_archive_but_admin_archive_appends() {
        let dir = std::env::temp_dir().join(format!("coevo_arch_{}", uuid::Uuid::new_v4()));
        let path = dir.join("deleted_users.ndjson");

        // ── 自助注销：不得写归档 ──
        {
            let conn = setup();
            seed_user(&conn, "u1");
            purge_user_with_archive(&conn, "u1", PurgeMode::SelfService, "self", &path).unwrap();
            assert!(
                !path.exists(),
                "自助注销产生了归档文件（含 email 明文）—— 与注销语义冲突"
            );
        }

        // ── 管理员硬删：写归档，且两次追加成两行 ──
        {
            let conn = setup();
            seed_user(&conn, "u2");
            let rep = purge_user_with_archive(&conn, "u2", PurgeMode::AdminArchive, "super", &path)
                .unwrap();
            assert!(rep.user_existed);

            let conn2 = setup();
            seed_user(&conn2, "u3");
            purge_user_with_archive(&conn2, "u3", PurgeMode::AdminArchive, "super", &path).unwrap();

            let content = std::fs::read_to_string(&path).unwrap();
            assert_eq!(
                content.lines().count(),
                2,
                "归档被覆盖了 —— 应为 append（每次一行）。内容: {}",
                content
            );
            // 🔴 归档内容必须在**删除前**取到 email（初版删后才取 ⇒ 只有 null）
            assert!(
                content.contains("u2@e.com") && content.contains("u3@e.com"),
                "归档里缺 email ⇒ 快照取晚了（应在 purge 之前）: {}",
                content
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }
}
