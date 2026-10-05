//! Auth — User registration and login
//!
//! Uses bcrypt for password hashing and UUID v4 for session tokens.
//! Tokens are stored in the `tokens` table for server-side verification.

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct ReferralInfo {
    pub code: Option<String>,
    pub campaign_id: Option<String>,
}

#[derive(Deserialize)]
pub struct RegisterRequest {
    /// 注册标识 = **邮箱**（2026-09-29 起）。
    ///
    /// 🔴 此前是 `username` + `real_name` + `phone` 三件套，其中后两者来自
    /// 微信时代的「实名 + 手机号」，产品已定不做 K12 → 一并移除
    /// （白哥 2026-09-29：「注册不要真实姓名和手机号，用邮箱注册+密码注册」）。
    pub email: String,
    pub password: String,
    pub referral: Option<ReferralInfo>,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    /// 登录标识 = **邮箱**（2026-09-29 起）。
    ///
    /// 🔴 此前支持「用户名 或 手机号」二选一（按 11 位数字猜）。
    ///    手机号分支已随 `phone_hash` 列一并移除 —— 那个分支前端从未接过
    ///    （`auth_client.login` 一直只传 username/password），是**死分支**。
    pub email: String,
    pub password: String,
}

#[derive(Serialize, Debug)]
pub struct AuthResponse {
    pub user_id: String,
    pub token: String,
    pub message: String,
    /// 已注册的邮箱；**未注册的 trial 匿名账号为 `None`**。
    ///
    /// 🔑 它取代了原来的 `real_name` —— 而原来的用途不是「显示姓名」，
    ///    是让前端判断「**这个账号是否已完成注册**」（`home_screen` 用它决定
    ///    要不要弹注册引导）。改邮箱后这个判断同样成立：`None` = 未注册。
    pub email: Option<String>,
}

/// 邮箱格式校验（**与前端 `Validators.email` 保持同一判据**）。
///
/// 🔑 `pub(crate)` —— `trial_handler::claim`（认领式注册）也用它。
///    **注册与认领必须同一套判据**：两处各写一份，规则会静默漂移，
///    而用户在界面上看不出差别（两个入口都叫「注册」）。
///
/// # ⚠️ 刻意宽松
///
/// 只要求：有且只有一个 `@` · `@` 两侧非空 · 域名含 `.` · 无空白 · 总长 ≤254。
///
/// 🔑 **为什么不写「严格」的正则**：过严的正则会拒掉**合法**邮箱 ——
///    `a+tag@x.co.uk`（子地址）· `用户@例子.中国`（国际化域名，punycode 前形态）…
///    而被拒的用户**没有任何办法绕过**，只能放弃注册。
///
/// 🔑 **真正的邮箱验证手段是「发验证邮件」，不是正则** —— 那是「登录页」批次的事
///    （`sign_in_with_apple` + 邮箱验证属同一批）。这里的正则只挡明显的手误。
pub(crate) fn is_valid_email(s: &str) -> bool {
    let s = s.trim();
    if s.is_empty() || s.len() > 254 || s.chars().any(|c| c.is_whitespace()) {
        return false;
    }
    let mut it = s.split('@');
    let local = it.next().unwrap_or("");
    let domain = it.next().unwrap_or("");
    // 超过一个 `@` → 拒绝
    if it.next().is_some() {
        return false;
    }
    !local.is_empty()
        && !domain.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
}

/// 从邮箱取默认昵称（`zhang@x.com` → `zhang`）。
///
/// 🔑 为什么要有这个：去掉 `username` 输入后，新账号的 `display_name` 会为空，
///    「我的」页副标题就会只剩「· 免费版」（`_displayName.isEmpty` 的兜底是「用户」）。
///    用邮箱前缀当默认昵称，比「用户」更有辨识度，且**不含 `@` 之后的域名**
///    （域名不必要地暴露在界面上）。
///
/// 🔑 `pub(crate)` —— `trial_handler::claim` 在**不改用户已设昵称**的前提下
///    用它补齐空昵称（`CASE WHEN display_name IS NULL OR '' THEN ? ELSE display_name END`）。
pub(crate) fn default_display_name(email: &str) -> String {
    email.split('@').next().unwrap_or("").trim().to_string()
}

/// Hash a password using bcrypt (with salt).
/// Returns the hashed password string, or empty string on failure.
pub fn hash_password(password: &str) -> String {
    bcrypt::hash(password, bcrypt::DEFAULT_COST).unwrap_or_else(|e| {
        tracing::error!("bcrypt hash failed: {}", e);
        String::new()
    })
}

/// Verify a password against a bcrypt hash.
fn verify_password(password: &str, hash: &str) -> bool {
    bcrypt::verify(password, hash).unwrap_or(false)
}

/// 密码强度规则 —— **全后端唯一权威**（注册 / 改密码 / 将来重置密码都调它）。
///
/// 规则：**至少 6 个字符** + 含 ASCII 英文字母 + 含数字。
///
/// # 🔴 2026-10-05 修：`len()` → `chars().count()`（口径修正）
///
/// 原实现用 `req.password.len() < 6` —— Rust 的 `String::len()` 是 **UTF-8 字节数**，
/// 而前端 `Validators.password` 用的是 Dart `String.length`（**UTF-16 code units**）。
/// 同一句「至少 6 位」，两侧**量纲不同**：
///
/// | 输入 | Dart `.length` | Rust `.len()` | 前端 | 后端 |
/// |---|---|---|---|---|
/// | `a1密码` | **4** | **8** | 拦 | **放行** ❌ |
///
/// ⇒ 前端更严、后端更松：**不经前端直接调 API 就能设一个 4 字符的密码**。
/// （当前产品只有 App 一个客户端，所以没被利用；但这属「跨实现一致性」缺陷，
///  且**将来若有网页端/脚本**就会成为真实弱点。）
/// 📌 判据：**同一个「口径」在两侧必须落到同一个定义** ——
///    「位数」指**字符数**，不是字节数。（含中文的密码尤其明显。）
/// 🔑 用 `chars().count()`：它数的是 **Unicode 标量值**，与「用户眼中的字数」一致。
/// ⚠️ 残留差异（如实标注）：Dart 的 `.length` 数的是 UTF-16 code units，
///    对**星形平面字符**（emoji 等）会算 2；Rust `chars()` 算 1。
///    本规则只要求「≥6」，这类字符通常伴随字母+数字出现 ⇒ 实际不会误判，
///    但**不是数学上的完全等价**，故如实记录于此。
pub fn validate_password_strength(password: &str) -> Result<(), String> {
    if password.chars().count() < 6
        || !password.chars().any(|c| c.is_ascii_alphabetic())
        || !password.chars().any(|c| c.is_ascii_digit())
    {
        return Err("密码至少6位含英文+数字".into());
    }
    Ok(())
}

/// Register a new user
pub fn register(
    conn: &rusqlite::Connection,
    req: &RegisterRequest,
) -> Result<AuthResponse, String> {
    // 校验（先格式后唯一性 —— 格式错的输入不必查库）
    if !is_valid_email(&req.email) {
        return Err("邮箱格式不正确".into());
    }
    // 🔑 密码规则**收敛到一处**（`validate_password_strength`）——
    //    注册与「修改密码」共用同一条，避免两处各写一份而漂移。
    validate_password_strength(&req.password)?;

    // 邮箱唯一性（大小写不敏感：邮箱的 local-part 技术上区分大小写，
    // 但**所有主流服务商**都按不敏感处理，而用户自己也记不清当时怎么打的
    // → 若按敏感处理，`A@x.com` 与 `a@x.com` 会变成两个账号，用户永远登不进前一个。
    // ⚠️ 唯一索引（`idx_users_email`）本身是**大小写敏感**的 —— 它挡的是完全相同的串；
    //    这里的 COLLATE NOCASE 查询是**业务层的更严要求**。两者不冲突：
    //    索引保证「不重复」，本查询保证「同义不重复」。）
    let email_exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE email = ?1 COLLATE NOCASE",
            rusqlite::params![req.email.trim()],
            |row| row.get::<_, i32>(0),
        )
        .map(|c| c > 0)
        .unwrap_or(false);
    if email_exists {
        return Err("该邮箱已被注册".into());
    }

    let user_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let token = uuid::Uuid::new_v4().to_string();
    let pwhash = hash_password(&req.password);

    if pwhash.is_empty() {
        return Err("Password hashing failed".into());
    }

    let email = req.email.trim().to_string();
    let display_name = default_display_name(&email);

    // 🔴 `username` 列现在**不由用户提供** —— 它是内部标识。
    //
    // 为什么不能删掉这一列：① 它是 `NOT NULL UNIQUE`（存量 91 行都有值）；
    // ② 它被 `isTrialAccount` 之类的判断用过（`trial_` 前缀）。
    // 注册标识已改为 `email` → 这里自动生成一个不对外的内部 id。
    // （trial 认领路径**不改** username，沿用它的 `trial_*` 值 → 见 `trial_handler`。）
    let username = format!(
        "u_{}",
        user_id
            .replace('-', "")
            .chars()
            .take(12)
            .collect::<String>()
    );

    // 查推广码对应的推广员（如果有）
    let referred_by: Option<String> = if let Some(ref ref_info) = req.referral {
        if let Some(ref code) = ref_info.code {
            // 查推广码对应的用户，且未被删除
            let referrer: Option<String> = conn
                .query_row(
                    "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
                    rusqlite::params![code],
                    |row| row.get(0),
                )
                .ok();
            referrer
        } else {
            None
        }
    } else {
        None
    };
    // 保存推广活动 ID（只有合法的 UUID 才写入，防止 camp=share 等非活动参数污染）
    let referred_campaign_id: Option<String> = req.referral.as_ref().and_then(|r| {
        r.campaign_id
            .as_ref()
            .filter(|c| c.len() == 36 && c.chars().filter(|&c| c == '-').count() == 4)
            .cloned()
    });

    // 生成用户自己的推广码（CoEvo_ + 4位大写字母数字，重试最多3次）
    let mut referral_code = String::new();
    for _ in 0..3 {
        use rand::Rng;
        let suffix: String = rand::thread_rng()
            .sample_iter(&rand::distributions::Alphanumeric)
            .take(4)
            .map(|c| c as char)
            .collect::<String>()
            .to_uppercase();
        let candidate = format!("CoEvo_{}", suffix);
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM users WHERE referral_code = ?1",
                rusqlite::params![candidate],
                |row| row.get::<_, i32>(0),
            )
            .map(|c| c > 0)
            .unwrap_or(false);
        if !exists {
            referral_code = candidate;
            break;
        }
    }

    conn.execute(
        "INSERT INTO users (id, username, display_name, password_hash, email, referral_code, referred_by, referred_campaign_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![user_id, username, display_name, pwhash, email, referral_code, referred_by, referred_campaign_id, now],
    ).map_err(|e| format!("Insert error: {}", e))?;

    // Store token in tokens table
    let token_id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    )
    .map_err(|e| format!("Token insert error: {}", e))?;

    // 触发注册活动（不阻塞注册）
    if let Err(e) = crate::campaign_executor::execute_campaign_trigger(
        conn,
        "registration",
        &user_id,
        referred_by.as_deref(),
        None,
        None,
    ) {
        tracing::warn!("registration campaign trigger failed: {}", e);
    }

    // 🔴 2026-09-29 已退役：推荐注册成就事件（成就改为「端侧计算」，后端不再处理）

    Ok(AuthResponse {
        user_id,
        token,
        message: "Registration successful".into(),
        email: Some(email),
    })
}

/// Delete all existing tokens for a user (to prevent token table bloat)
fn cleanup_old_tokens(conn: &rusqlite::Connection, user_id: &str) {
    if let Err(e) = conn.execute(
        "DELETE FROM tokens WHERE user_id = ?1",
        rusqlite::params![user_id],
    ) {
        tracing::warn!("Failed to clean old tokens for {}: {}", user_id, e);
    }
}

/// Login with **email** (rejects soft-deleted users)
///
/// 🔴 2026-09-29：此前的「用户名 **或** 手机号」二选一收敛为**邮箱**。
///    手机号分支随 `phone_hash` 列一并移除 —— 它**前端从未接过**
///    （`auth_client.login` 一直只传 username/password），是死分支。
///
/// ⚠️ 存量 91 行账号（`username` 为 `test1` / `trial_*`）**没有 email** →
///    它们无法经本接口登录。这是**有意**的：那批是内测/测试账号，
///    生产环境在 2026-09-29 核实为**零真实用户**。
pub fn login(conn: &rusqlite::Connection, req: &LoginRequest) -> Result<AuthResponse, String> {
    // 🔑 统一错误信息，**不区分**「邮箱不存在」与「密码错误」——
    //    否则这个接口可以被用来**枚举哪些邮箱注册过**（撞库的第一步）。
    //    （这也是原实现的意图，原注释：「不泄露是用户名/手机号错了还是密码错了」。）
    const ERR: &str = "邮箱或密码错误";

    // ⚠️ `password_hash` 可空（trial 匿名账号未设密码）→ 取 `Option<String>`。
    //    直接 `row.get::<_, String>` 遇到 NULL 会报错；这里让它走到 bcrypt 验证，
    //    空 hash 必然验证失败 —— 语义正确且不 panic。
    let (user_id, stored_hash, email): (String, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT id, password_hash, email FROM users \
             WHERE email = ?1 COLLATE NOCASE AND deleted_at IS NULL",
            rusqlite::params![req.email.trim()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|_| ERR.to_string())?;

    if !verify_password(&req.password, stored_hash.as_deref().unwrap_or("")) {
        return Err(ERR.to_string());
    }

    // Clean up old tokens for this user before creating a new one
    cleanup_old_tokens(conn, &user_id);

    let token = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let token_id = uuid::Uuid::new_v4().to_string();

    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    )
    .map_err(|e| format!("Token insert error: {}", e))?;

    Ok(AuthResponse {
        user_id,
        token,
        message: "Login successful".into(),
        email,
    })
}

/// 修改密码请求（已登录用户）。
#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    /// 原密码 —— 🔴 **必须验**，见 `change_password` 的安全要点 ①。
    pub old_password: String,
    /// 新密码 —— 强度规则与注册**同一条**（`validate_password_strength`）。
    pub new_password: String,
}

/// 修改密码（已登录）。成功返回 `Ok(())`。
///
/// # 为什么这个功能必须有（不只是体验）
///
/// 它和「忘记密码」在**账号维护功能**清单里是并列的两项 ——
/// 只有「忘记密码」的话，用户**记得密码时反而改不了**（想换一个更强的密码都做不到）。
///
/// # 🔴 三个安全要点（缺一条就是真漏洞）
///
/// | # | 要点 | 不做的后果 |
/// |---|---|---|
/// | ① | **必须验原密码** | 「拿到已解锁设备的人」可静默改密码，主人**再也登不回来** |
/// | ② | **改完失效其他会话**（保留当前） | 账号被盗后主人改密码，**攻击者的会话仍然有效** |
/// | ③ | **新密码不得与原密码相同** | 「修改」变成空操作，而用户以为改成功了 |
///
/// ## ② 的实现取舍（如实标注）
///
/// 本系统的 `login` 本就调 `cleanup_old_tokens`（删该用户**全部** token 再建新的）
/// ⇒ **实际上是单会话模型**。所以这里用「删掉除当前 token 之外的全部」表达
/// 「其他设备都登出、当前这台继续用」—— 与用户预期一致，且不依赖「是否真的多端」。
/// ⚠️ 若将来为「跨设备同步」放宽为多会话，本函数**不用改**（语义已正确）。
///
/// ## 为什么「原密码错误」可以明说（不像登录那样含糊）
///
/// `login` 必须含糊（「邮箱或密码错误」）以防**邮箱枚举** —— 那是撞库第一步。
/// 本接口**已经通过 token 鉴权**、且报错只回给**账号本人**，不存在枚举面
/// ⇒ 明确说「原密码不正确」对用户更友好，且不引入新风险。
pub fn change_password(
    conn: &rusqlite::Connection,
    user_id: &str,
    current_token: &str,
    req: &ChangePasswordRequest,
) -> Result<(), String> {
    // ── 先校验新密码强度（格式错的输入不必查库）──
    // 🔑 与注册共用同一条规则 —— 判据「跨实现一致」。
    validate_password_strength(&req.new_password)?;

    // ── 取当前 hash ──
    let stored_hash: Option<String> = conn
        .query_row(
            "SELECT password_hash FROM users WHERE id = ?1 AND deleted_at IS NULL",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .map_err(|_| "账号不存在或已注销".to_string())?;

    // 🔴 匿名试用账号**没有密码**（`password_hash` 为 NULL）——
    //    它的「获得密码」路径是**注册/认领**（`/api/trial/claim`），不是改密码。
    //    这里明确报错，而不是让它走到 bcrypt 然后回一句含糊的「原密码不正确」
    //    （那会让用户以为「我输错了」，而实际是「你还没有密码」）。
    let Some(hash) = stored_hash else {
        return Err("该账号尚未设置密码，请先完成注册".to_string());
    };

    // ── ① 验原密码 ──
    if !verify_password(&req.old_password, &hash) {
        return Err("原密码不正确".to_string());
    }

    // ── ③ 新旧相同视为无效 ──
    // ⚠️ 顺序放在「验原密码之后」：先证明确实是本人，再告知这条业务规则
    //    （否则没通过验证的人也能探到「新密码与旧密码是否相同」这一点信息）。
    if req.new_password == req.old_password {
        return Err("新密码不能与原密码相同".to_string());
    }

    // ── 写回新 hash ──
    let new_hash = hash_password(&req.new_password);
    if new_hash.is_empty() {
        return Err("密码保存失败，请重试".to_string());
    }
    conn.execute(
        "UPDATE users SET password_hash = ?1 WHERE id = ?2",
        rusqlite::params![new_hash, user_id],
    )
    .map_err(|e| {
        tracing::error!("change_password: 更新 hash 失败: {}", e);
        "密码保存失败，请重试".to_string()
    })?;

    // ── ② 失效其他会话（保留当前）──
    match conn.execute(
        "DELETE FROM tokens WHERE user_id = ?1 AND token != ?2",
        rusqlite::params![user_id, current_token],
    ) {
        Ok(n) => tracing::info!("change_password: 已失效 {} 个其他会话", n),
        // ⚠️ 不 fail：密码**已经改成功了**，把「踢会话」失败报成整体失败会误导用户
        //    （他会以为没改成功而重试 —— 而重试会因「新旧相同」被拒，更困惑）。
        //    如实记日志，让运维侧可见；当前会话仍受 token 校验保护。
        Err(e) => tracing::warn!("change_password: 清理其他会话失败（密码已更新）: {}", e),
    }

    Ok(())
}

/// 用会话 token 反查 `user_id` —— **全后端唯一权威**（见 `user_purge` 的同名包装）。
///
/// 🔑 抽出来的理由：注销（`user_purge`）与改密码都要做这件事 ⇒
///    两处各写一份 SQL 的话，将来若加「token 过期校验」必漏一处。
pub fn uid_by_token(conn: &rusqlite::Connection, token: &str) -> Result<String, String> {
    conn.query_row(
        "SELECT user_id FROM tokens WHERE token = ?1 LIMIT 1",
        rusqlite::params![token],
        |r| r.get::<_, String>(0),
    )
    .map_err(|_| "登录已失效，请重新登录".to_string())
}

/// Verify a session token against the database.
/// Returns `true` if the token exists for the given user and the user is not soft-deleted.
pub fn verify_token(conn: &rusqlite::Connection, user_id: &str, token: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM tokens t JOIN users u ON t.user_id = u.id WHERE t.user_id = ?1 AND t.token = ?2",
        rusqlite::params![user_id, token],
        |_| Ok(true),
    ).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn
    }

    #[test]
    fn test_bcrypt_produces_different_hashes() {
        let h1 = hash_password("password123");
        let h2 = hash_password("password123");
        assert!(!h1.is_empty());
        assert!(!h2.is_empty());
        // Bcrypt generates different hashes for the same password due to salting
        assert_ne!(
            h1, h2,
            "bcrypt should produce different hashes for same password"
        );
    }

    #[test]
    fn test_verify_password_works() {
        let hash = hash_password("mypassword");
        assert!(verify_password("mypassword", &hash));
        assert!(!verify_password("wrongpassword", &hash));
    }

    #[test]
    fn test_register_and_login() {
        let conn = setup_db();

        // Register
        let resp = register(
            &conn,
            &RegisterRequest {
                email: "alice@example.com".into(),
                password: "secret1".into(),
                referral: None,
            },
        )
        .unwrap();
        assert_eq!(resp.user_id.len(), 36, "user_id should be a UUID v4");
        assert!(!resp.token.is_empty());
        assert_eq!(resp.email.as_deref(), Some("alice@example.com"));

        // Login —— 🔴 用**邮箱**（原来是 username）
        let resp2 = login(
            &conn,
            &LoginRequest {
                email: "alice@example.com".into(),
                password: "secret1".into(),
            },
        )
        .unwrap();
        assert_eq!(resp2.user_id, resp.user_id);
        assert!(!resp2.token.is_empty());
    }

    /// 🔑 注册后 `display_name` 自动取邮箱前缀（否则「我的」页副标题只剩「· 免费版」）。
    #[test]
    fn test_register_sets_display_name_from_email_prefix() {
        let conn = setup_db();
        register(
            &conn,
            &RegisterRequest {
                email: "zhangsan@example.com".into(),
                password: "secret1".into(),
                referral: None,
            },
        )
        .unwrap();

        let dn: String = conn
            .query_row(
                "SELECT display_name FROM users WHERE email = 'zhangsan@example.com'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(dn, "zhangsan", "display_name 应为邮箱前缀，且不含域名");
    }

    #[test]
    fn test_login_wrong_password() {
        let conn = setup_db();

        register(
            &conn,
            &RegisterRequest {
                email: "bobby@example.com".into(),
                password: "correct1".into(),
                referral: None,
            },
        )
        .unwrap();

        let result = login(
            &conn,
            &LoginRequest {
                email: "bobby@example.com".into(),
                password: "wrong1".into(),
            },
        );
        assert!(result.is_err());
        // 错误文案**不区分**「邮箱不存在」与「密码错」—— 否则可用来枚举已注册邮箱
        assert_eq!(result.unwrap_err(), "邮箱或密码错误");
    }

    #[test]
    fn test_register_duplicate_email() {
        let conn = setup_db();

        register(
            &conn,
            &RegisterRequest {
                email: "charlie@example.com".into(),
                password: "pw1pass".into(),
                referral: None,
            },
        )
        .unwrap();

        let result = register(
            &conn,
            &RegisterRequest {
                email: "charlie@example.com".into(),
                password: "pw2pass".into(),
                referral: None,
            },
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("已被注册"));
    }

    /// 🔴 邮箱唯一性**大小写不敏感**。
    ///
    /// 为什么必须这样：邮箱的 local-part 技术上区分大小写，但**所有主流服务商**
    /// 都按不敏感处理，而用户自己也记不清注册时怎么打的。
    /// 若按敏感处理，`Alice@x.com` 与 `alice@x.com` 会变成两个账号 ——
    /// 用户用另一种大小写登录时永远进不去那个已有学习记录的账号。
    #[test]
    fn test_register_email_is_case_insensitive() {
        let conn = setup_db();

        register(
            &conn,
            &RegisterRequest {
                email: "alice@example.com".into(),
                password: "pw1pass".into(),
                referral: None,
            },
        )
        .unwrap();

        // 全大写形式应被判为重复
        let dup = register(
            &conn,
            &RegisterRequest {
                email: "ALICE@EXAMPLE.COM".into(),
                password: "pw2pass".into(),
                referral: None,
            },
        );
        assert!(dup.is_err(), "大小写不同的同一邮箱应判为重复");

        // 用全大写形式**登录**应成功（命中同一账号）
        let ok = login(
            &conn,
            &LoginRequest {
                email: "ALICE@EXAMPLE.COM".into(),
                password: "pw1pass".into(),
            },
        );
        assert!(ok.is_ok(), "大小写不同的同一邮箱应能登进同一账号");
    }

    #[test]
    fn test_register_rejects_invalid_email() {
        let conn = setup_db();
        let result = register(
            &conn,
            &RegisterRequest {
                email: "not-an-email".into(),
                password: "pw1pass".into(),
                referral: None,
            },
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("邮箱格式不正确"));
    }

    /// 🔑 邮箱格式校验的**边界**（正反双向）。
    ///
    /// ⚠️ 这个测试的价值在于**防止正则被写得太严** ——
    ///    过严会拒掉合法邮箱（`a+tag@x.co.uk` 这类子地址），
    ///    而被拒的用户**没有任何办法绕过**，只能放弃注册。
    #[test]
    fn test_is_valid_email_boundaries() {
        // ✅ 合法
        assert!(is_valid_email("a@b.co"));
        assert!(is_valid_email("a+tag@x.co.uk"), "子地址（+tag）必须合法");
        assert!(is_valid_email("first.last@sub.domain.org"));
        assert!(is_valid_email("  a@b.co  "), "两端空白应被 trim 后判为合法");

        // ❌ 非法
        assert!(!is_valid_email(""));
        assert!(!is_valid_email("no-at-sign"));
        assert!(!is_valid_email("a@b"), "域名必须含点");
        assert!(!is_valid_email("a@.b"), "域名不能以点开头");
        assert!(!is_valid_email("a@b."), "域名不能以点结尾");
        assert!(!is_valid_email("a b@c.co"), "不能含空白");
        assert!(!is_valid_email("a@@b.co"), "只能有一个 @");
        assert!(!is_valid_email("@b.co"), "local 部分不能为空");
        assert!(!is_valid_email("a@"), "域名不能为空");
    }

    /// 默认昵称 = 邮箱前缀，且**不含 `@` 之后的域名**。
    #[test]
    fn test_default_display_name() {
        assert_eq!(default_display_name("zhangsan@example.com"), "zhangsan");
        assert_eq!(default_display_name("a@b.co"), "a");
        assert_eq!(default_display_name("  padded@x.co  "), "padded");
    }

    #[test]
    fn test_token_verification_with_db() {
        let conn = setup_db();

        let resp = register(
            &conn,
            &RegisterRequest {
                email: "davey@example.com".into(),
                password: "pass12".into(),
                referral: None,
            },
        )
        .unwrap();

        // Valid token should verify
        assert!(verify_token(&conn, &resp.user_id, &resp.token));

        // Wrong token should not verify
        assert!(!verify_token(&conn, &resp.user_id, "wrong-token"));

        // Wrong user should not verify
        assert!(!verify_token(&conn, "wrong-user", &resp.token));
    }

    /// 🔴 手机号登录分支**已移除**（2026-09-29）。
    ///
    /// 原实现会按「11 位、以 1 开头、全数字」猜出输入是手机号，再查 `phone_hash`。
    /// 该分支**前端从未接过**（`auth_client.login` 一直只传 username/password），
    /// 且两列已删 → 现在同一串数字会被当成一个**格式非法的邮箱** → 查不到 → 报错。
    #[test]
    fn test_login_by_phone_no_longer_works() {
        let conn = setup_db();
        register(
            &conn,
            &RegisterRequest {
                email: "phoneuser@example.com".into(),
                password: "pass123".into(),
                referral: None,
            },
        )
        .unwrap();

        let result = login(
            &conn,
            &LoginRequest {
                email: "13800138000".into(),
                password: "pass123".into(),
            },
        );
        assert!(result.is_err(), "手机号不再能登录 —— 已改用注册邮箱");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 🆕 2026-10-05 修改密码（`change_password`）+ 密码校验收敛
    // ════════════════════════════════════════════════════════════════════════

    /// 建一个已注册用户，返回 `(user_id, token)`。
    fn seed_user(conn: &Connection, email: &str, pw: &str) -> (String, String) {
        let r = register(
            conn,
            &RegisterRequest {
                email: email.into(),
                password: pw.into(),
                referral: None,
            },
        )
        .unwrap();
        (r.user_id, r.token)
    }

    #[test]
    fn test_validate_password_strength_rules() {
        // 合法
        assert!(validate_password_strength("abc123").is_ok());
        assert!(validate_password_strength("a12345").is_ok());
        // 太短（5 个字符）
        assert!(validate_password_strength("ab123").is_err(), "5 位应拒绝");
        // 缺字母 / 缺数字
        assert!(
            validate_password_strength("123456").is_err(),
            "纯数字应拒绝"
        );
        assert!(
            validate_password_strength("abcdef").is_err(),
            "纯字母应拒绝"
        );
    }

    /// 🔴 **回归测试：`len()` → `chars().count()` 的口径修正（2026-10-05）**
    ///
    /// 原实现用 `password.len()`（UTF-8 **字节数**）判「≥6 位」，而前端用
    /// Dart `String.length`（**字符数**）⇒ 两侧量纲不同，后端更松：
    /// `"a1密码"` 的字节数是 **8**（1+1+3+3）⇒ 旧实现**放行**，
    /// 而它在用户眼里只有 **4 个字符** —— 不经前端直接调 API 就能设弱密码。
    ///
    /// 📌 这条断言锁的是「**口径 = 字符数**」，不是某个具体长度值。
    #[test]
    fn test_password_length_counts_chars_not_bytes() {
        // 「a1」+ 两个汉字 = 4 个字符 / 8 字节
        let pw = "a1密码";
        assert_eq!(pw.len(), 8, "前提：UTF-8 字节数确实是 8");
        assert_eq!(pw.chars().count(), 4, "前提：字符数确实是 4");
        assert!(
            validate_password_strength(pw).is_err(),
            "🔴 「a1密码」只有 4 个字符 ⇒ 必须拒绝（旧实现按字节算 8 会放行）"
        );

        // 6 个字符（4 汉字 + a1）⇒ 应通过
        assert!(validate_password_strength("密码密码a1").is_ok());
    }

    #[test]
    fn test_change_password_happy_path() {
        let conn = setup_db();
        let (uid, token) = seed_user(&conn, "cp@example.com", "old123");

        change_password(
            &conn,
            &uid,
            &token,
            &ChangePasswordRequest {
                old_password: "old123".into(),
                new_password: "new456".into(),
            },
        )
        .expect("改密码应成功");

        // 新密码可登录
        assert!(login(
            &conn,
            &LoginRequest {
                email: "cp@example.com".into(),
                password: "new456".into(),
            },
        )
        .is_ok());
        // 旧密码不可登录
        assert!(login(
            &conn,
            &LoginRequest {
                email: "cp@example.com".into(),
                password: "old123".into(),
            },
        )
        .is_err());
    }

    #[test]
    fn test_change_password_rejects_wrong_old_password() {
        let conn = setup_db();
        let (uid, token) = seed_user(&conn, "cp2@example.com", "old123");

        let e = change_password(
            &conn,
            &uid,
            &token,
            &ChangePasswordRequest {
                old_password: "WRONG1".into(),
                new_password: "new456".into(),
            },
        )
        .unwrap_err();
        assert_eq!(e, "原密码不正确");

        // 🔴 关键：失败后**密码必须没变**（防「验失败却已写入」这类顺序 bug）
        assert!(login(
            &conn,
            &LoginRequest {
                email: "cp2@example.com".into(),
                password: "old123".into(),
            },
        )
        .is_ok());
    }

    #[test]
    fn test_change_password_rejects_weak_and_identical() {
        let conn = setup_db();
        let (uid, token) = seed_user(&conn, "cp3@example.com", "old123");

        // 新密码太弱 ⇒ 拒绝（**且应在查库之前**，此处不校验顺序，只校验结果）
        let e = change_password(
            &conn,
            &uid,
            &token,
            &ChangePasswordRequest {
                old_password: "old123".into(),
                new_password: "12345".into(),
            },
        )
        .unwrap_err();
        assert_eq!(e, "密码至少6位含英文+数字");

        // 新旧相同 ⇒ 拒绝
        let e = change_password(
            &conn,
            &uid,
            &token,
            &ChangePasswordRequest {
                old_password: "old123".into(),
                new_password: "old123".into(),
            },
        )
        .unwrap_err();
        assert_eq!(e, "新密码不能与原密码相同");
    }

    /// 🔴 匿名试用账号（`password_hash` 为 NULL）改密码要**明确报错**，
    /// 而不是含糊地说「原密码不正确」—— 用户会以为是自己输错了。
    #[test]
    fn test_change_password_on_passwordless_account() {
        let conn = setup_db();
        // 造一个无密码账号（模拟 trial 匿名账号）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES ('u-trial', 'trial_abc', NULL, 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) \
             VALUES ('t1', 'u-trial', 'tok-1', 0)",
            [],
        )
        .unwrap();

        let e = change_password(
            &conn,
            "u-trial",
            "tok-1",
            &ChangePasswordRequest {
                old_password: "whatever1".into(),
                new_password: "new456".into(),
            },
        )
        .unwrap_err();
        assert!(
            e.contains("尚未设置密码"),
            "应明确说明「还没有密码」而不是「原密码不正确」，实得：{e}"
        );
    }

    /// 🔴 **安全要点 ②**：改密码后**其他会话失效、当前会话保留**。
    ///
    /// 不做这件事的后果：账号被盗后主人改密码，**攻击者的会话仍然有效**。
    #[test]
    fn test_change_password_invalidates_other_sessions_keeps_current() {
        let conn = setup_db();
        let (uid, token_a) = seed_user(&conn, "cp4@example.com", "old123");

        // 模拟第二台设备登录（直接插 token —— 走 login 会清掉全部，不便构造多会话）
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) VALUES ('tb', ?1, 'token-b', 0)",
            rusqlite::params![uid],
        )
        .unwrap();

        let count = |t: &str| -> i64 {
            conn.query_row(
                "SELECT COUNT(*) FROM tokens WHERE token = ?1",
                rusqlite::params![t],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!(count(&token_a), 1, "前提：当前会话在");
        assert_eq!(count("token-b"), 1, "前提：另一会话在");

        change_password(
            &conn,
            &uid,
            &token_a,
            &ChangePasswordRequest {
                old_password: "old123".into(),
                new_password: "new456".into(),
            },
        )
        .unwrap();

        assert_eq!(count(&token_a), 1, "🔴 当前会话必须保留（否则自己也被踢）");
        assert_eq!(
            count("token-b"),
            0,
            "🔴 其他会话必须失效（防被盗号会话留存）"
        );
    }

    #[test]
    fn test_uid_by_token() {
        let conn = setup_db();
        let (uid, token) = seed_user(&conn, "ubt@example.com", "abc123");

        assert_eq!(uid_by_token(&conn, &token).unwrap(), uid);
        assert!(
            uid_by_token(&conn, "not-a-real-token").is_err(),
            "无效 token 应报错"
        );
    }
}
