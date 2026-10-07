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

    // 🔴 2026-10-06 已退役：注册后触发营销活动（原 `campaign_executor::execute_campaign_trigger`）
    //    —— 分销/营销链整体删除，见 `docs/review/backend-dead-route-cleanup-2026-10-06.md`

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

// ══════════════════════════════════════════════════════════════════════════
// 「忘记密码」（自助重置）—— 与「修改密码」并列的另一半
// ══════════════════════════════════════════════════════════════════════════
//
// 📄 为什么必须两个都有 → `docs/design/forgot-password-ui-2026-10-05.html`
// 📄 邮件通道（腾讯云 SES）→ `docs/operations/tencent-ses-onboarding-2026-10-05.md`

/// 重置验证码的有效期（秒）—— **10 分钟**。
pub const RESET_CODE_TTL_SECS: i64 = 600;
/// 同一邮箱两次「申请验证码」之间的最小间隔（秒）—— 防刷 + 控制发信成本。
pub const RESET_CODE_COOLDOWN_SECS: i64 = 60;
/// 同一个验证码允许的最大错误次数 —— 达到即**作废**该码（防 6 位码被穷举）。
pub const RESET_CODE_MAX_ATTEMPTS: i64 = 5;

/// 生成一个 **6 位数字**验证码，含前导零（如 `"004271"`）。
///
/// 🔑 用 `gen_range(0..1_000_000)` + `{:06}` 而不是「随机 6 个数字拼接」：
///    前者每一位都是独立均匀的，后者容易写出「首位不为 0」这类偏斜
///    （而偏斜会把 10^6 的搜索空间缩小，直接削弱防暴力能力）。
fn generate_reset_code() -> String {
    use rand::Rng;
    let n: u32 = rand::thread_rng().gen_range(0..1_000_000);
    format!("{:06}", n)
}

/// 「忘记密码」第 1 步：为该邮箱**签发**一个验证码并落库。
///
/// # 返回值
///
/// | 返回 | 含义 | 调用方应做什么 |
/// |---|---|---|
/// | `Ok(code)` | 签发成功，明文码**只在此刻可见** | 立刻发信，把 `code` 发出去 |
/// | `Err(msg)` | 邮箱未注册 / 格式非法 / 距上次申请不足 60 秒 | 把 `msg` 原样给前端 |
///
/// # 🔴 为什么明文码只返回一次、之后无处可查
///
/// 表里只存 bcrypt hash —— 库被拿走也还原不出码。
/// 代价是「码只在这一刻可得」⇒ 调用方**必须**在同一个请求里把信发出去。
///
/// # 🔴 「邮箱未注册」显式报错 —— 白哥 2026-10-05 定，**有意**的取舍
///
/// 本函数**知道**这个选择会带来什么，如实记在这里：
///
/// | | 含糊（`login` 的做法）| **明说（本函数，白哥定）** |
/// |---|---|---|
/// | 防邮箱枚举 | ✅ 不能探测「哪些邮箱注册过」 | ❌ **可以**探测 |
/// | 用户打错邮箱时 | 🔴 一直等一封**永远不会来**的邮件 | ✅ 立刻知道「这邮箱没注册」 |
///
/// 🔑 **为什么这里选了和 `login` 相反的一侧**：
///   · `login` 的含糊是**必须**的 —— 那里泄露的是「密码对不对」，
///     配合撞库直接威胁已有账号；
///   · 这里泄露的只是「这个邮箱在本站注册过」，**不涉及任何凭据**；
///   · 而代价是**真实的用户伤害**：打错一个字母就要干等十分钟
///     （且用户会以为「系统坏了」—— 属「静默失败」那一族）。
/// 📌 判据：**含糊与明说的取舍要看「泄露什么 × 换来什么」**，
///    不能机械照搬「登录必须含糊」这条规则 —— 两者泄露的东西完全不同。
/// ⚠️ 风险已知并接受：本项目**个人运营、用户量小、无定向攻击动机**；
///    若将来出现「批量探测」迹象（如大量 404 邮箱的申请），
///    这里应改回含糊（改动范围：本函数 + `reset_password` + 两条测试）。
pub fn issue_reset_code(conn: &rusqlite::Connection, email: &str) -> Result<String, String> {
    let email = email.trim();
    if !is_valid_email(email) {
        return Err("邮箱格式不正确".into());
    }

    // ── 查用户（大小写不敏感，与 login / register 同一判据）──
    let user_id: Option<String> = conn
        .query_row(
            "SELECT id FROM users WHERE email = ?1 COLLATE NOCASE AND deleted_at IS NULL",
            rusqlite::params![email],
            |row| row.get(0),
        )
        .ok();

    let Some(user_id) = user_id else {
        // 🔴 明说（见上方注释的取舍表）—— 与 `login` 的含糊**有意不同**
        return Err("该邮箱尚未注册".into());
    };

    let now = chrono::Utc::now().timestamp();

    // ── 限流：同一邮箱 60 秒内只能申请一次 ──
    // 🔑 必须有：① 每次申请都**真发一封邮件**（有成本/有信誉风险）；
    //            ② 不限速的话，攻击者可高频申请把 6 位码的搜索空间压小。
    let last: Option<i64> = conn
        .query_row(
            "SELECT created_at FROM password_reset WHERE user_id = ?1 \
             ORDER BY created_at DESC LIMIT 1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok();
    if let Some(last) = last {
        if now - last < RESET_CODE_COOLDOWN_SECS {
            return Err("发送太频繁，请稍后再试".into());
        }
    }

    // ── 签发 ──
    let code = generate_reset_code();
    let code_hash = hash_password(&code);
    if code_hash.is_empty() {
        return Err("验证码生成失败，请重试".into());
    }
    let id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO password_reset (id, user_id, code_hash, attempts, expires_at, created_at) \
         VALUES (?1, ?2, ?3, 0, ?4, ?5)",
        rusqlite::params![id, user_id, code_hash, now + RESET_CODE_TTL_SECS, now],
    )
    .map_err(|e| {
        tracing::error!("issue_reset_code: 写库失败: {}", e);
        "验证码生成失败，请重试".to_string()
    })?;

    tracing::info!("issue_reset_code: 已签发给 user_id={}", user_id);
    Ok(code)
}

/// 「忘记密码」第 2 步：用验证码重置密码。
///
/// 成功返回与 [`login`] **同形**的响应（含新 `token`）⇒ 前端可**直接进 App**（自动登录）。
///
/// # 校验顺序（有讲究，别调换）
///
/// 1. **新密码强度** —— 格式错的输入不必查库
/// 2. **用户存在** —— 不存在则回「该邮箱尚未注册」（与第 1 步一致，见下）
/// 3. **取最新一条未用未过期的码** —— 没有 → 「已失效，请重新获取」
/// 4. **是否过期**
/// 5. **比对码** —— 错则 `attempts + 1`；达上限则**作废**（见 [`RESET_CODE_MAX_ATTEMPTS`]）
/// 6. **改密码 → 用掉码 → 删全部会话 → 签发新 token**（**一个事务**）
///
/// # 🔴 与「修改密码」的关键差异 —— 不要合并这两个函数
///
/// | | 修改密码 | 忘记密码 |
/// |---|---|---|
/// | 用户状态 | **已登录** | **未登录**（登不进来才来重置）|
/// | 旧会话 | **保留当前**、踢其他 | **全部删除** |
/// | 理由 | 主人正在用这台设备 | 没有「当前会话」；且重置常发生在「怀疑被盗」时 |
pub fn reset_password(
    conn: &rusqlite::Connection,
    email: &str,
    code: &str,
    new_password: &str,
) -> Result<AuthResponse, String> {
    // ── 1. 新密码强度（与注册 / 改密码**同一条**规则 —— 全后端唯一权威）──
    validate_password_strength(new_password)?;

    let email = email.trim();
    let user_id: Option<String> = conn
        .query_row(
            "SELECT id FROM users WHERE email = ?1 COLLATE NOCASE AND deleted_at IS NULL",
            rusqlite::params![email],
            |row| row.get(0),
        )
        .ok();
    // ── 2. 未注册 ⇒ 明说（与 `issue_reset_code` 保持一致）──
    // 🔑 这里**不再**含糊：第 1 步已经明说过了，枚举面**已经开了**
    //    ⇒ 此处含糊**没有额外保护价值**，只会让用户困惑
    //    （「第一步说没注册，第二步说验证码不对，到底哪个是真的？」）。
    let Some(user_id) = user_id else {
        return Err("该邮箱尚未注册".into());
    };

    let now = chrono::Utc::now().timestamp();

    // ── 3. 取最新一条「未用」的码 ──
    let row: Option<(String, String, i64, i64)> = conn
        .query_row(
            "SELECT id, code_hash, attempts, expires_at FROM password_reset \
             WHERE user_id = ?1 AND used_at IS NULL ORDER BY created_at DESC LIMIT 1",
            rusqlite::params![user_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .ok();
    let Some((pr_id, code_hash, attempts, expires_at)) = row else {
        return Err("验证码已失效，请重新获取".into());
    };

    // ── 4. 过期 ──
    if now > expires_at {
        return Err("验证码已过期，请重新获取".into());
    }

    // ── 5. 比对（bcrypt · 恒定时长 ⇒ 不能靠响应时间逐位猜）──
    if !verify_password(code.trim(), &code_hash) {
        let next = attempts + 1;
        if next >= RESET_CODE_MAX_ATTEMPTS {
            // 🔴 达上限 ⇒ **作废这个码**（标 `used_at`），迫使用户重新申请。
            //    不这么做，攻击者可无限次试 —— 6 位码只有 10^6 种，
            //    不限次就等于没有防暴力能力。
            if let Err(e) = conn.execute(
                "UPDATE password_reset SET attempts = ?1, used_at = ?2 WHERE id = ?3",
                rusqlite::params![next, now, pr_id],
            ) {
                tracing::warn!("reset_password: 作废验证码失败: {}", e);
            }
            return Err("尝试次数过多，请重新获取验证码".into());
        }
        if let Err(e) = conn.execute(
            "UPDATE password_reset SET attempts = ?1 WHERE id = ?2",
            rusqlite::params![next, pr_id],
        ) {
            tracing::warn!("reset_password: 累加尝试次数失败: {}", e);
        }
        return Err("验证码不正确".into());
    }

    // ── 6. 通过：改密码 + 用掉码 + 换新会话（**原子**）──
    let new_hash = hash_password(new_password);
    if new_hash.is_empty() {
        return Err("密码保存失败，请重试".into());
    }

    // 🔑 用 `unchecked_transaction`（只需 `&Connection`，与 `db_pool` 的共享连接兼容）
    //    把三步包成原子。不做事务的两种坏结果：
    //      · 改了密码但没换 token → 用户拿旧 token 继续用，而我们以为已重置
    //      · 码标了已用但密码没改 → 用户被彻底锁死（码废了、密码还是旧的）
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("事务开启失败: {}", e))?;

    tx.execute(
        "UPDATE users SET password_hash = ?1 WHERE id = ?2",
        rusqlite::params![new_hash, user_id],
    )
    .map_err(|e| {
        tracing::error!("reset_password: 更新 hash 失败: {}", e);
        "密码保存失败，请重试".to_string()
    })?;

    tx.execute(
        "UPDATE password_reset SET used_at = ?1 WHERE id = ?2",
        rusqlite::params![now, pr_id],
    )
    .map_err(|e| format!("密码保存失败，请重试: {}", e))?;

    // 🔴 删掉该用户**全部** token（与「修改密码」相反 —— 见上方差异表）
    tx.execute(
        "DELETE FROM tokens WHERE user_id = ?1",
        rusqlite::params![user_id],
    )
    .map_err(|e| format!("密码保存失败，请重试: {}", e))?;

    // 签发新 token（自动登录）
    let token = uuid::Uuid::new_v4().to_string();
    let token_id = uuid::Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    )
    .map_err(|e| format!("密码保存失败，请重试: {}", e))?;

    tx.commit()
        .map_err(|e| format!("密码保存失败，请重试: {}", e))?;

    // 顺带清理该用户其余的历史验证码（防表无限增长）。
    // ⚠️ 放在事务**之外**且失败只记日志 —— 密码已经改成功了，
    //    把「清理旧码失败」报成整体失败会误导用户去重试（而码已被用掉）。
    if let Err(e) = conn.execute(
        "DELETE FROM password_reset WHERE user_id = ?1 AND id != ?2",
        rusqlite::params![user_id, pr_id],
    ) {
        tracing::warn!("reset_password: 清理历史验证码失败（不影响结果）: {}", e);
    }

    tracing::info!("reset_password: 重置成功（已失效该用户全部旧会话）");
    Ok(AuthResponse {
        user_id,
        token,
        message: "Password reset successful".into(),
        email: Some(email.to_string()),
    })
}

// ══════════════════════════════════════════════════════════════════════════
// 「修改邮箱」—— 与「修改密码」并列的**账号敏感操作**
// ══════════════════════════════════════════════════════════════════════════
//
// 📌 为什么需要「验当前密码 + 验新邮箱的码」两道：
//    邮箱是**登录标识**（也是「忘记密码」的收信地址）⇒ 换掉它就等于换了找回途径。
//    · 只验新邮箱的码 ⇒ 拿到已解锁设备的人可把邮箱改成自己的，随后走「忘记密码」
//      **彻底接管账号**（与 `change_password` 注释 ①「必须验原密码」同一条理由）。
//    · 只验密码 ⇒ 能把账号换绑到**别人的**邮箱（格式合法但非本人所有）
//      ⇒ 那个邮箱的主人会莫名收到验证码，且原主人被锁在外面。
//    ⇒ 两个凭据各挡一类攻击，缺一不可。

/// 修改邮箱验证码的有效期（秒）—— **10 分钟**（与找回密码同档）。
pub const EMAIL_CHANGE_TTL_SECS: i64 = 600;
/// 同一用户两次「申请换绑」之间的最小间隔（秒）—— 防刷 + 控制发信成本。
pub const EMAIL_CHANGE_COOLDOWN_SECS: i64 = 60;
/// 同一个验证码允许的最大错误次数 —— 达到即**作废**该码（与找回密码同一防暴力口径）。
pub const EMAIL_CHANGE_MAX_ATTEMPTS: i64 = 5;

/// 「修改邮箱」第 1 步：给**用户想换成的那个新邮箱**签发验证码。
///
/// # 返回值
///
/// | 返回 | 含义 | 调用方应做什么 |
/// |---|---|---|
/// | `Ok(code)` | 签发成功，明文码**只在此刻可见** | 立刻发信到 `new_email` |
/// | `Err(msg)` | 密码错 / 格式非法 / 该邮箱已被占用 / 与当前相同 / 60 秒内重复 | 把 `msg` 原样给前端 |
///
/// # 🔴 「新邮箱已被占用」明说 —— 与 [`issue_reset_code`] 同一条取舍
///
/// 含糊的代价是**真实的用户伤害**：用户会一直等一封**永远不会来**的邮件
/// （且以为系统坏了 ⇒ 「静默失败」那一族）。
/// 而此处**调用方已通过密码鉴权**，不存在匿名枚举面
/// ⇒ 明说更优。（`login` 的含糊是另一回事：那里泄露的是「密码对不对」。）
pub fn issue_email_change_code(
    conn: &rusqlite::Connection,
    user_id: &str,
    current_password: &str,
    new_email: &str,
) -> Result<String, String> {
    let new_email = new_email.trim();
    if !is_valid_email(new_email) {
        return Err("邮箱格式不正确".into());
    }

    // ── ① 验当前密码（证明是账号主人）──
    let stored_hash: Option<String> = conn
        .query_row(
            "SELECT password_hash FROM users WHERE id = ?1 AND deleted_at IS NULL",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .map_err(|_| "账号不存在或已注销".to_string())?;
    // 匿名试用账号没有密码 —— 它「获得邮箱」的路径是注册/认领，不是改邮箱
    // （同 `change_password` 的处理：明确报错，而不是让用户以为「我输错了」）。
    let Some(hash) = stored_hash else {
        return Err("该账号尚未设置密码，请先完成注册".to_string());
    };
    if !verify_password(current_password, &hash) {
        return Err("当前密码不正确".to_string());
    }

    // ── ② 与当前邮箱相同 ⇒ 无意义操作（在验密码**之后**才说，避免未验证者探测）──
    let current_email: Option<String> = conn
        .query_row(
            "SELECT email FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    if let Some(cur) = current_email.as_ref() {
        if cur.eq_ignore_ascii_case(new_email) {
            return Err("新邮箱与当前邮箱相同".into());
        }
    }

    // ── ③ 新邮箱是否已被**别人**占用 ──
    // 判据与 `register` 完全一致（COLLATE NOCASE）—— 同一件事只能有一个口径。
    let taken: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE email = ?1 COLLATE NOCASE \
             AND deleted_at IS NULL AND id != ?2",
            rusqlite::params![new_email, user_id],
            |row| row.get::<_, i32>(0),
        )
        .map(|c| c > 0)
        .unwrap_or(false);
    if taken {
        return Err("该邮箱已被其他账号使用".into());
    }

    let now = chrono::Utc::now().timestamp();

    // ── ④ 限流：同一用户 60 秒一次 ──
    let last: Option<i64> = conn
        .query_row(
            "SELECT created_at FROM email_change WHERE user_id = ?1 \
             ORDER BY created_at DESC LIMIT 1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok();
    if let Some(last) = last {
        if now - last < EMAIL_CHANGE_COOLDOWN_SECS {
            return Err("发送太频繁，请稍后再试".into());
        }
    }

    // ── ⑤ 签发（**只存 hash**，明文只在这一刻存在）──
    let code = generate_reset_code();
    let code_hash = hash_password(&code);
    if code_hash.is_empty() {
        return Err("验证码生成失败，请重试".into());
    }
    let id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO email_change \
         (id, user_id, new_email, code_hash, attempts, expires_at, used_at, created_at) \
         VALUES (?1, ?2, ?3, ?4, 0, ?5, NULL, ?6)",
        rusqlite::params![
            id,
            user_id,
            new_email,
            code_hash,
            now + EMAIL_CHANGE_TTL_SECS,
            now
        ],
    )
    .map_err(|e| {
        tracing::error!("issue_email_change_code: 写库失败: {}", e);
        "验证码生成失败，请重试".to_string()
    })?;

    tracing::info!("issue_email_change_code: 已签发给 user_id={}", user_id);
    Ok(code)
}

/// 「修改邮箱」第 2 步：用验证码完成换绑。成功返回**新邮箱**。
///
/// # 校验顺序（与 [`reset_password`] 同构，别调换）
///
/// 1. 新邮箱格式
/// 2. 取最新一条「未用」的码 —— 🔴 **必须同时匹配 `new_email`**
///    （否则「用 A 邮箱收到的码」可以完成「改到 B 邮箱」）
/// 3. 是否过期
/// 4. 比对码 —— 错则 `attempts + 1`；达上限则**作废**
/// 5. **再查一次唯一性**（发码 → 用码之间该邮箱可能被别人抢注 —— TOCTOU）
/// 6. **换绑 + 用掉码**（**一个事务**）
///
/// # 🔴 为什么这一步不再验密码
///
/// 第 1 步已经验过（那是「发码」的前提）。本步的安全性由**另一个独立凭据**保证：
/// **确实收到了发往新邮箱的验证码**。重复验密码只会让用户在两步之间输两次，
/// 而**不增加任何安全性**（能走到第 1 步的人本来就知道密码）。
pub fn change_email(
    conn: &rusqlite::Connection,
    user_id: &str,
    new_email: &str,
    code: &str,
) -> Result<String, String> {
    let new_email = new_email.trim();
    if !is_valid_email(new_email) {
        return Err("邮箱格式不正确".into());
    }

    let now = chrono::Utc::now().timestamp();

    // ── 取最新一条未用的码（🔴 `new_email` 必须一起匹配，见上头第 2 条）──
    let row: Option<(String, String, i64, i64)> = conn
        .query_row(
            "SELECT id, code_hash, attempts, expires_at FROM email_change \
             WHERE user_id = ?1 AND new_email = ?2 AND used_at IS NULL \
             ORDER BY created_at DESC LIMIT 1",
            rusqlite::params![user_id, new_email],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .ok();
    let Some((ec_id, code_hash, attempts, expires_at)) = row else {
        return Err("验证码已失效，请重新获取".into());
    };

    if now > expires_at {
        return Err("验证码已过期，请重新获取".into());
    }

    // ── 比对（bcrypt · 恒定时长）──
    if !verify_password(code.trim(), &code_hash) {
        let next = attempts + 1;
        if next >= EMAIL_CHANGE_MAX_ATTEMPTS {
            // 达上限 ⇒ 作废该码（否则 6 位码可被无限次试）
            if let Err(e) = conn.execute(
                "UPDATE email_change SET attempts = ?1, used_at = ?2 WHERE id = ?3",
                rusqlite::params![next, now, ec_id],
            ) {
                tracing::warn!("change_email: 作废验证码失败: {}", e);
            }
            return Err("尝试次数过多，请重新获取验证码".into());
        }
        if let Err(e) = conn.execute(
            "UPDATE email_change SET attempts = ?1 WHERE id = ?2",
            rusqlite::params![next, ec_id],
        ) {
            tracing::warn!("change_email: 累加尝试次数失败: {}", e);
        }
        return Err("验证码不正确".into());
    }

    // ── 🔴 再查一次唯一性（TOCTOU：发码到用码之间，该邮箱可能已被别人注册）──
    let taken: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE email = ?1 COLLATE NOCASE \
             AND deleted_at IS NULL AND id != ?2",
            rusqlite::params![new_email, user_id],
            |row| row.get::<_, i32>(0),
        )
        .map(|c| c > 0)
        .unwrap_or(false);
    if taken {
        return Err("该邮箱已被其他账号使用".into());
    }

    // ── 取旧邮箱（用于「昵称是否还是旧邮箱前缀」的判断）──
    let old_email: Option<String> = conn
        .query_row(
            "SELECT email FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();

    // 🔑 `display_name` 为空、或**仍等于旧邮箱前缀**（= 用户从未自定义过昵称）
    //    ⇒ 顺带更新为新前缀。否则「我的」页会一直显示一个**已不存在的**邮箱前缀。
    //    ⚠️ 用户自己设过昵称 ⇒ 一个字都不动（那是他的选择）。
    let new_display_name: Option<String> = match old_email.as_deref() {
        Some(old) => {
            let old_prefix = default_display_name(old);
            let cur: Option<String> = conn
                .query_row(
                    "SELECT display_name FROM users WHERE id = ?1",
                    rusqlite::params![user_id],
                    |row| row.get(0),
                )
                .ok()
                .flatten();
            match cur {
                None => Some(default_display_name(new_email)),
                Some(d) if d == old_prefix => Some(default_display_name(new_email)),
                _ => None, // 用户自定义过 ⇒ 不动
            }
        }
        None => Some(default_display_name(new_email)),
    };

    // ── 换绑 + 用掉码（**原子**）──
    // 不做事务的坏结果：改了邮箱但码没标已用 ⇒ 同一个码还能再改一次
    //（而新邮箱现在归这个账号了，第二次改会命中「与当前邮箱相同」——
    //  看似无害，但那是**碰巧**被另一条规则挡住，不是本流程的保证）。
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("事务开启失败: {}", e))?;

    match &new_display_name {
        Some(name) => tx.execute(
            "UPDATE users SET email = ?1, display_name = ?2 WHERE id = ?3",
            rusqlite::params![new_email, name, user_id],
        ),
        None => tx.execute(
            "UPDATE users SET email = ?1 WHERE id = ?2",
            rusqlite::params![new_email, user_id],
        ),
    }
    .map_err(|e| {
        // 唯一索引冲突（并发下的最后一道闸）也走这里
        tracing::error!("change_email: 更新邮箱失败: {}", e);
        "邮箱保存失败，请重试".to_string()
    })?;

    tx.execute(
        "UPDATE email_change SET used_at = ?1 WHERE id = ?2",
        rusqlite::params![now, ec_id],
    )
    .map_err(|e| format!("邮箱保存失败，请重试: {}", e))?;

    tx.commit()
        .map_err(|e| format!("邮箱保存失败，请重试: {}", e))?;

    // 清理该用户其余历史码（放事务**之外**，失败只记日志 ——
    // 邮箱已经改成功了，把它报成失败会让用户去重试一个已完成的动作）。
    if let Err(e) = conn.execute(
        "DELETE FROM email_change WHERE user_id = ?1 AND id != ?2",
        rusqlite::params![user_id, ec_id],
    ) {
        tracing::warn!("change_email: 清理历史验证码失败（不影响结果）: {}", e);
    }

    tracing::info!("change_email: 换绑成功");
    Ok(new_email.to_string())
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

    // ═══════════════════ 找回密码（「忘记密码」）═══════════════════

    /// 未注册邮箱 ⇒ **显式报错**（白哥 2026-10-05 定「明说」）。
    ///
    /// 🔴 这条断言在 2026-10-05 从**反向**改过来 —— 原实现是「静默返回 `Ok(None)`」，
    ///    断言也照着写（`matches!(..., Ok(None))`）。白哥改选「明说」后，
    ///    **断言必须跟着事实走**（否则它会「保护错误」：代码改对了反而变红）。
    /// 📌 同族判据：「断言会保护错误」+「事实作废后断言要反向」。
    ///
    /// 🔑 仍然守住的那一半（与「明说」无关，**必须**一直成立）：
    ///    未注册邮箱**绝不写库**（否则会凭空产生一条无主的验证码记录）。
    #[test]
    fn test_issue_reset_code_unknown_email_is_explicit() {
        let conn = setup_db();
        let err = issue_reset_code(&conn, "nobody@example.com").unwrap_err();
        assert_eq!(err, "该邮箱尚未注册", "白哥定「明说」⇒ 必须显式告知");

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM password_reset", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0, "未注册邮箱绝不能写入验证码表");
    }

    #[test]
    fn test_issue_reset_code_rejects_invalid_email() {
        let conn = setup_db();
        assert!(issue_reset_code(&conn, "not-an-email").is_err());
        // 已注册的账号配上非法邮箱串，同样拦在前面
        seed_user(&conn, "ok@example.com", "abc123");
        assert!(
            issue_reset_code(&conn, "ok@example").is_err(),
            "缺顶级域应被拒"
        );
    }

    /// 码必须是 **6 位数字**，且库里存的是 **bcrypt hash**（不是明文）。
    #[test]
    fn test_issued_code_is_six_digits_and_hashed() {
        let conn = setup_db();
        seed_user(&conn, "a@example.com", "abc123");

        let code = issue_reset_code(&conn, "a@example.com").unwrap();
        assert_eq!(code.len(), 6, "必须 6 位：{code}");
        assert!(
            code.chars().all(|c| c.is_ascii_digit()),
            "必须全数字：{code}"
        );

        let stored: String = conn
            .query_row("SELECT code_hash FROM password_reset", [], |r| r.get(0))
            .unwrap();
        assert_ne!(stored, code, "🔴 库里不能是明文验证码");
        assert!(stored.starts_with("$2"), "应是 bcrypt hash，实际 {stored}");
    }

    #[test]
    fn test_issue_reset_code_cooldown() {
        let conn = setup_db();
        seed_user(&conn, "b@example.com", "abc123");
        issue_reset_code(&conn, "b@example.com").unwrap();

        let err = issue_reset_code(&conn, "b@example.com").unwrap_err();
        assert!(err.contains("频繁"), "60 秒内二次申请应被限流：{err}");
    }

    /// 成功重置：新 token 可用 · 旧会话**全清** · 新密码能登、旧密码不能。
    #[test]
    fn test_reset_password_happy_path() {
        let conn = setup_db();
        let (uid, _old_token) = seed_user(&conn, "c@example.com", "secret1");

        let code = issue_reset_code(&conn, "c@example.com").unwrap();
        let resp = reset_password(&conn, "c@example.com", &code, "newpass1").unwrap();

        assert_eq!(resp.user_id, uid);
        assert!(
            verify_token(&conn, &uid, &resp.token),
            "🔴 重置后应立即自动登录（新 token 必须有效）"
        );
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM tokens WHERE user_id = ?1",
                [&uid],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1, "🔴 旧会话必须全部失效（只剩刚签发的新 token）");

        assert!(
            login(
                &conn,
                &LoginRequest {
                    email: "c@example.com".into(),
                    password: "newpass1".into()
                }
            )
            .is_ok(),
            "新密码必须能登录"
        );
        assert!(
            login(
                &conn,
                &LoginRequest {
                    email: "c@example.com".into(),
                    password: "secret1".into()
                }
            )
            .is_err(),
            "旧密码必须失效"
        );
    }

    /// 码错 4 次仍可用；第 5 次达上限 ⇒ 文案变化 + **该码作废**（连正确的码也不能再用）。
    #[test]
    fn test_reset_password_attempt_limit_locks_code() {
        let conn = setup_db();
        seed_user(&conn, "d@example.com", "abc123");
        let code = issue_reset_code(&conn, "d@example.com").unwrap();
        // 一个「长度对但值不同」的码
        let wrong = if code == "000000" { "000001" } else { "000000" };

        for i in 1..=4 {
            let err = reset_password(&conn, "d@example.com", wrong, "newpass1").unwrap_err();
            assert_eq!(err, "验证码不正确", "第 {i} 次错误应是普通文案");
        }
        let err = reset_password(&conn, "d@example.com", wrong, "newpass1").unwrap_err();
        assert!(err.contains("尝试次数过多"), "第 5 次应达上限：{err}");

        // 作废之后，**正确的码**也不能再用（迫使重新申请）
        let err2 = reset_password(&conn, "d@example.com", &code, "newpass1").unwrap_err();
        assert!(err2.contains("失效"), "码应已作废：{err2}");
    }

    #[test]
    fn test_reset_password_expired_code_rejected() {
        let conn = setup_db();
        seed_user(&conn, "e@example.com", "abc123");
        let code = issue_reset_code(&conn, "e@example.com").unwrap();

        // 把过期时间推到过去
        conn.execute("UPDATE password_reset SET expires_at = 1", [])
            .unwrap();

        let err = reset_password(&conn, "e@example.com", &code, "newpass1").unwrap_err();
        assert!(err.contains("过期"), "{err}");
    }

    /// 强度校验发生在**验码之前** ⇒ 弱密码被拒时**不会消耗**那条码。
    #[test]
    fn test_reset_password_rejects_weak_password_without_burning_code() {
        let conn = setup_db();
        seed_user(&conn, "f@example.com", "abc123");
        let code = issue_reset_code(&conn, "f@example.com").unwrap();

        assert!(
            reset_password(&conn, "f@example.com", &code, "a1").is_err(),
            "太短"
        );
        assert!(
            reset_password(&conn, "f@example.com", &code, "abcdefg").is_err(),
            "无数字"
        );
        assert!(
            reset_password(&conn, "f@example.com", &code, "1234567").is_err(),
            "无字母"
        );

        // 码仍在 ⇒ 用合规密码能成功
        assert!(
            reset_password(&conn, "f@example.com", &code, "goodpass1").is_ok(),
            "🔑 被强度校验拒掉的尝试不应消耗验证码"
        );
    }

    /// 码是**一次性**的。
    #[test]
    fn test_reset_code_is_single_use() {
        let conn = setup_db();
        seed_user(&conn, "g@example.com", "abc123");
        let code = issue_reset_code(&conn, "g@example.com").unwrap();

        assert!(reset_password(&conn, "g@example.com", &code, "newpass1").is_ok());
        let err = reset_password(&conn, "g@example.com", &code, "newpass2").unwrap_err();
        assert!(err.contains("失效"), "同一个码不能复用：{err}");

        assert!(login(
            &conn,
            &LoginRequest {
                email: "g@example.com".into(),
                password: "newpass1".into()
            }
        )
        .is_ok());
    }

    /// 未注册邮箱 ⇒ **明说**（与第 1 步 `issue_reset_code` 一致）。
    ///
    /// 🔑 为什么不在这里单独「含糊」：第 1 步已经明说过了，枚举面**已经开了**
    ///    ⇒ 此处含糊没有额外保护价值，只会让用户困惑。两处**必须同口径**。
    #[test]
    fn test_reset_password_unknown_email_is_explicit() {
        let conn = setup_db();
        let err = reset_password(&conn, "nobody@example.com", "123456", "newpass1").unwrap_err();
        assert_eq!(err, "该邮箱尚未注册", "两处必须同口径（都明说）");
    }

    /// 邮箱大小写不敏感（与 `register` / `login` 同一判据）。
    #[test]
    fn test_reset_password_email_case_insensitive() {
        let conn = setup_db();
        seed_user(&conn, "Mixed@Example.com", "abc123");
        let code = issue_reset_code(&conn, "mixed@example.com").unwrap();
        assert!(
            reset_password(&conn, "MIXED@EXAMPLE.COM", &code, "newpass1").is_ok(),
            "邮箱大小写不同也应能找到账号"
        );
    }

    /// 重置成功后，历史验证码被清理（只留刚用过的那条），防表无限增长。
    #[test]
    fn test_reset_password_prunes_old_codes() {
        let conn = setup_db();
        seed_user(&conn, "h@example.com", "abc123");
        // 手动插入 3 条历史码（模拟多次申请）
        for i in 0..3 {
            conn.execute(
                "INSERT INTO password_reset (id, user_id, code_hash, attempts, expires_at, used_at, created_at) \
                 VALUES (?1, (SELECT id FROM users WHERE email='h@example.com'), 'x', 0, 1, 1, ?2)",
                rusqlite::params![format!("old-{i}"), 1000 + i],
            )
            .unwrap();
        }
        let code = issue_reset_code(&conn, "h@example.com").unwrap();
        assert!(reset_password(&conn, "h@example.com", &code, "newpass1").is_ok());

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM password_reset", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "应只剩刚用过的那条，实际 {n}");
    }

    /// `generate_reset_code` 恒为 6 位（含前导零也必须补足）。
    /// 🔑 直接跑 200 次 —— 这是个**概率性**函数，只测一次抓不到「偶尔 5 位」。
    #[test]
    fn test_generate_reset_code_always_six_digits() {
        for _ in 0..200 {
            let c = generate_reset_code();
            assert_eq!(c.len(), 6, "恒 6 位：{c}");
            assert!(c.chars().all(|ch| ch.is_ascii_digit()), "恒数字：{c}");
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 修改邮箱（2026-10-07）
    // ══════════════════════════════════════════════════════════════════

    /// 🔴 **核心安全断言**：第 1 步必须验**当前密码**。
    ///
    /// 若这里放行，拿到「已解锁设备」的人可以（不知道密码）把邮箱换成自己的，
    /// 随后走「忘记密码」**彻底接管账号** —— 与 `change_password` 必须验原密码同理。
    #[test]
    fn test_issue_email_change_code_rejects_wrong_password() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "a@example.com", "old123");

        let err = issue_email_change_code(&conn, &uid, "WRONG-pw", "new@example.com").unwrap_err();
        assert_eq!(err, "当前密码不正确", "密码错必须拒绝");

        // 正确密码 ⇒ 通过（证明确实是「密码」这道门，而不是别的校验误拦）
        assert!(issue_email_change_code(&conn, &uid, "old123", "new@example.com").is_ok());
    }

    /// 新邮箱已被**别人**注册 ⇒ 明说（否则用户等一封永远不来的邮件）。
    #[test]
    fn test_issue_email_change_code_rejects_taken_email() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "a@example.com", "old123");
        seed_user(&conn, "taken@example.com", "other123");

        let err = issue_email_change_code(&conn, &uid, "old123", "taken@example.com").unwrap_err();
        assert_eq!(err, "该邮箱已被其他账号使用");
    }

    /// 新邮箱与当前邮箱相同（含**大小写不同**的同一邮箱）⇒ 无意义操作，拒绝。
    #[test]
    fn test_issue_email_change_code_rejects_same_email() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "same@example.com", "old123");

        let err = issue_email_change_code(&conn, &uid, "old123", "same@example.com").unwrap_err();
        assert_eq!(err, "新邮箱与当前邮箱相同");

        // 大小写不同也是同一个邮箱（与 register / login 同一判据 COLLATE NOCASE）
        let err2 = issue_email_change_code(&conn, &uid, "old123", "SAME@Example.COM").unwrap_err();
        assert_eq!(err2, "新邮箱与当前邮箱相同", "大小写不同应视为同一邮箱");
    }

    /// 匿名试用账号（`password_hash` 为 NULL）没有密码 ⇒ 明确报错，
    /// 而不是让用户以为「我输错了原密码」。它的路径是注册/认领。
    #[test]
    fn test_issue_email_change_code_on_passwordless_account() {
        let conn = setup_db();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, email, created_at) \
             VALUES ('trial-u1', 'trial_abc', NULL, NULL, 1)",
            [],
        )
        .unwrap();

        let err =
            issue_email_change_code(&conn, "trial-u1", "whatever", "new@example.com").unwrap_err();
        assert_eq!(err, "该账号尚未设置密码，请先完成注册");
    }

    /// Happy path：签发 → 换绑 → **新邮箱能登录、旧邮箱登不进来**。
    /// 🔑 必须验证「登录」这一层 —— 只断言 `users.email` 变了是不够的，
    ///    那证明不了「用户真的能用新邮箱进来」（示例：唯一索引没走通时的中间态）。
    #[test]
    fn test_change_email_happy_path() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "old@example.com", "abc123");

        let code = issue_email_change_code(&conn, &uid, "abc123", "brand-new@example.com").unwrap();
        let returned = change_email(&conn, &uid, "brand-new@example.com", &code).unwrap();
        assert_eq!(returned, "brand-new@example.com");

        // 新邮箱可登录
        assert!(
            login(
                &conn,
                &LoginRequest {
                    email: "brand-new@example.com".into(),
                    password: "abc123".into(),
                }
            )
            .is_ok(),
            "换绑后必须能用新邮箱登录"
        );
        // 旧邮箱登不进来
        assert!(
            login(
                &conn,
                &LoginRequest {
                    email: "old@example.com".into(),
                    password: "abc123".into(),
                }
            )
            .is_err(),
            "旧邮箱必须失效"
        );

        // 昵称跟随更新（原昵称 = 旧邮箱前缀 "old"，用户没自定义过）
        let dn: String = conn
            .query_row(
                "SELECT display_name FROM users WHERE id = ?1",
                rusqlite::params![uid],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(dn, "brand-new", "未自定义过昵称 ⇒ 应跟随新邮箱前缀");
    }

    /// 用户**自定义过**昵称 ⇒ 换邮箱时一个字都不动（那是他的选择）。
    #[test]
    fn test_change_email_keeps_custom_display_name() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "old2@example.com", "abc123");
        conn.execute(
            "UPDATE users SET display_name = '我的昵称' WHERE id = ?1",
            rusqlite::params![uid],
        )
        .unwrap();

        let code = issue_email_change_code(&conn, &uid, "abc123", "n2@example.com").unwrap();
        change_email(&conn, &uid, "n2@example.com", &code).unwrap();

        let dn: String = conn
            .query_row(
                "SELECT display_name FROM users WHERE id = ?1",
                rusqlite::params![uid],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(dn, "我的昵称", "自定义昵称不该被覆盖");
    }

    /// 🔴🔴 **码必须与「目标新邮箱」绑定** —— 用 A 邮箱收到的码**不能**完成「改到 B 邮箱」。
    ///
    /// 若这里不按 `new_email` 过滤，则「能收到 A 的人」可以把账号改到任意 B
    /// （只要他也在同一时间申请过一次 B 的码 —— 或更糟：服务端只取「最新一条码」时，
    ///  两个并行的改邮箱请求会互相串味）。
    #[test]
    fn test_change_email_code_is_bound_to_target_email() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "bind@example.com", "abc123");

        let code_a =
            issue_email_change_code(&conn, &uid, "abc123", "a-target@example.com").unwrap();
        let err = change_email(&conn, &uid, "b-target@example.com", &code_a).unwrap_err();
        assert!(
            err.contains("失效"),
            "A 邮箱的码不能用于改到 B 邮箱，实际：{err}"
        );

        // 原样用 A 的码改 A ⇒ 仍然有效（证明上面的失败是「绑错邮箱」，不是码被作废）
        assert!(change_email(&conn, &uid, "a-target@example.com", &code_a).is_ok());
    }

    /// 验证码**单次有效**（用掉后不能再改一次）。
    #[test]
    fn test_change_email_code_is_single_use() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "once@example.com", "abc123");

        let code = issue_email_change_code(&conn, &uid, "abc123", "n1@example.com").unwrap();
        assert!(change_email(&conn, &uid, "n1@example.com", &code).is_ok());

        let err = change_email(&conn, &uid, "n1@example.com", &code).unwrap_err();
        assert!(err.contains("失效"), "同一个码不能复用：{err}");
    }

    /// 🔴 **TOCTOU**：发码 → 用码之间，目标邮箱可能被**别人**抢先注册
    /// ⇒ 第 2 步必须再查一次唯一性（否则会把两个账号的 email 撞成同一个值）。
    #[test]
    fn test_change_email_rechecks_uniqueness_at_step_two() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "race@example.com", "abc123");

        // ① 发码时该邮箱还空着
        let code =
            issue_email_change_code(&conn, &uid, "abc123", "race-target@example.com").unwrap();
        // ② 别人抢注了它
        seed_user(&conn, "race-target@example.com", "thief123");
        // ③ 用码 ⇒ 必须被拦
        let err = change_email(&conn, &uid, "race-target@example.com", &code).unwrap_err();
        assert_eq!(err, "该邮箱已被其他账号使用", "第 2 步必须重查唯一性");

        // 该码**不被作废**（是业务冲突，不是猜码）⇒ 用户换个邮箱申请即可
        // ⚠️ 这里不断言「码仍可用」：目标是同一个邮箱，重试仍会撞占用 —— 那是预期的。
        //    只断言「没有把两个账号写成同一个 email」。
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM users WHERE email = 'race-target@example.com'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1, "同一邮箱绝不能落进两个账号");
    }

    /// 错误次数达上限 ⇒ **作废该码**（6 位码只有 10^6 种，不限次等于没有防暴力能力）。
    #[test]
    fn test_change_email_attempt_limit_locks_code() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "brute@example.com", "abc123");
        let code = issue_email_change_code(&conn, &uid, "abc123", "bt@example.com").unwrap();
        // 🔑 保证错误码**不等于**真码（1/10^6 的概率会让这条测试偶发假红）
        let wrong = if code == "000000" { "111111" } else { "000000" };

        for _ in 0..EMAIL_CHANGE_MAX_ATTEMPTS {
            let _ = change_email(&conn, &uid, "bt@example.com", wrong);
        }
        // 码已作废 ⇒ 即使拿**正确的**码也不行
        let err = change_email(&conn, &uid, "bt@example.com", &code).unwrap_err();
        assert!(
            err.contains("尝试次数过多") || err.contains("失效"),
            "达上限后该码必须作废，实际：{err}"
        );
    }

    /// 验证码过期 ⇒ 拒绝。
    #[test]
    fn test_change_email_expired_code_rejected() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "exp@example.com", "abc123");
        let code = issue_email_change_code(&conn, &uid, "abc123", "et@example.com").unwrap();

        // 把过期时间改到过去
        conn.execute(
            "UPDATE email_change SET expires_at = 1 WHERE user_id = ?1",
            rusqlite::params![uid],
        )
        .unwrap();

        let err = change_email(&conn, &uid, "et@example.com", &code).unwrap_err();
        assert!(err.contains("过期"), "实际：{err}");
    }

    /// 换绑成功后，历史验证码被清理（只留刚用过的那条）—— 防表无限增长。
    #[test]
    fn test_change_email_prunes_old_codes() {
        let conn = setup_db();
        let (uid, _) = seed_user(&conn, "prune@example.com", "abc123");
        // 手动插 3 条历史码（模拟多次申请 —— 走 cooldown 才不冲突）
        for i in 0..3 {
            conn.execute(
                "INSERT INTO email_change \
                 (id, user_id, new_email, code_hash, attempts, expires_at, used_at, created_at) \
                 VALUES (?1, ?2, 'x@example.com', 'x', 0, 1, 1, ?3)",
                rusqlite::params![format!("ec-old-{i}"), uid, 1000 + i],
            )
            .unwrap();
        }
        let code =
            issue_email_change_code(&conn, &uid, "abc123", "prune-target@example.com").unwrap();
        change_email(&conn, &uid, "prune-target@example.com", &code).unwrap();

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM email_change", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "应只剩刚用过的那条，实际 {n}");
    }
}
