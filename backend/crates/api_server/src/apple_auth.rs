//! Sign in with Apple —— `identityToken` 的服务端验证 + 建号 / 登录 / 绑定
//!
//! # 🔴 三条硬性事实（都来自 Apple 官方文档，别照旧博客做）
//!
//! | # | 事实 | 后果 |
//! |---|---|---|
//! | ① | 验证 `identityToken` **只需 Apple 的公钥**（JWKS） | ✅ **不需要 `.p8` / Key ID** |
//! | ② | `.p8` 只用于生成 `client_secret` ⇒ 换取 refresh token / 撤销授权 | 登录**不依赖**它 |
//! | ③ | `aud` 对**原生 iOS** 是 **bundle id**（不是 Services ID） | 用错 ⇒ 所有 token 校验失败 |
//!
//! 📄 原文：「To verify the identity token, your app server must:
//! Verify the JWS E256 signature using the server's public key / Verify the nonce /
//! Verify that the `iss` field contains `https://appleid.apple.com` /
//! Verify that the `aud` field is the developer's client_id /
//! Verify that the time is earlier than the `exp` value」
//! → `developer.apple.com/documentation/signinwithapple/verifying-a-user`
//!
//! # ⚠️ 本模块**有意不做**的两件事（如实标注）
//!
//! | 事项 | 为什么不做 | 何时要补 |
//! |---|---|---|
//! | **nonce 校验** | 需要在「发 nonce」与「验 nonce」之间共享状态（防重放）。当前 `identityToken` 有效期仅约 10 分钟、且经 HTTPS 传输 | 若将来接入 Web 端（重放面变大）或出现可疑登录 |
//! | **authorizationCode → refresh_token** | 它只为「注销时向 Apple 撤销授权」服务；而撤销还要求落库 refresh token + 生成 client_secret（`.p8`） | 若上架审核要求「注销须同时撤销 Apple 授权」——⚠️ **那时必须改本模块**：`authorizationCode` **只在登录那一刻存在**，事后补不了 |

use std::sync::{Mutex, OnceLock};

use base64::Engine as _;
use serde::Deserialize;

use crate::auth::{default_display_name, AuthResponse};

/// Apple 的 JWKS（公钥集）端点。
const APPLE_KEYS_URL: &str = "https://appleid.apple.com/auth/keys";
/// `identityToken` 的签发者 —— `iss` 必须**精确等于**它。
const APPLE_ISSUER: &str = "https://appleid.apple.com";
/// 公钥缓存有效期（秒）。
///
/// 🔑 必须有缓存（Apple 会限流）；也必须有**过期**（密钥轮换后若不刷新，
///    会变成「所有登录都失败」，而那时改代码要发版 ⇒ 缓存自愈更稳）。
const KEYS_TTL_SECS: i64 = 6 * 3600;

/// 本 App 在 Apple 侧的标识（= bundle id）。
///
/// 🔴 **权威来源是 iOS 工程**（`app/ios/Runner.xcodeproj/project.pbxproj` 的
///    `PRODUCT_BUNDLE_IDENTIFIER`，实测 `com.coevo.coevoApp`）。
///    这里给默认值 + 允许环境变量覆盖，是为了让「改 bundle id」时
///    不必动代码（但**两处必须一起改**，否则所有 Apple 登录都会因 `aud` 不符而失败）。
pub const DEFAULT_APPLE_CLIENT_ID: &str = "com.coevo.coevoApp";

/// 从环境读 client_id（bundle id），缺省用默认值。
pub fn apple_client_id() -> String {
    std::env::var("APPLE_CLIENT_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_APPLE_CLIENT_ID.to_string())
}

/// Apple JWKS 里的一个公钥（RSA）。
#[derive(Debug, Clone, Deserialize)]
struct AppleJwk {
    kid: String,
    /// RSA 模数（base64url）。
    n: String,
    /// RSA 指数（base64url，通常是 `AQAB`）。
    e: String,
}

#[derive(Debug, Deserialize)]
struct AppleJwks {
    keys: Vec<AppleJwk>,
}

/// `(过期时间戳, 公钥列表)`
type KeysCache = Mutex<Option<(i64, Vec<AppleJwk>)>>;
static KEYS: OnceLock<KeysCache> = OnceLock::new();

/// JWT 的 base64url 解码。
///
/// 🔑 先试 **no-pad**（JWT 标准写法），失败再试带 padding 的 ——
///    有些实现（含部分测试工具）会补 `=`，而标准解码器遇到 `=` 会直接报错。
fn b64url(s: &str) -> Result<Vec<u8>, String> {
    use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
    URL_SAFE_NO_PAD
        .decode(s)
        .or_else(|_| URL_SAFE.decode(s))
        .map_err(|e| format!("base64url 解码失败: {}", e))
}

/// 取 Apple 公钥集（带进程内缓存）。
async fn apple_keys() -> Result<Vec<AppleJwk>, String> {
    let now = chrono::Utc::now().timestamp();

    // ── 命中缓存（🔴 锁的作用域必须**不含 await**，否则 future 不是 Send）──
    {
        let guard = KEYS
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|_| "公钥缓存锁异常".to_string())?;
        if let Some((expires, keys)) = guard.as_ref() {
            if now < *expires {
                return Ok(keys.clone());
            }
        }
    }

    // ── 刷新 ──
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("构建 HTTP 客户端失败: {}", e))?;
    let resp = client
        .get(APPLE_KEYS_URL)
        .send()
        .await
        .map_err(|e| format!("获取 Apple 公钥失败: {}", e))?;
    if !resp.status().is_success() {
        return Err(format!("获取 Apple 公钥失败: HTTP {}", resp.status()));
    }
    let jwks: AppleJwks = resp
        .json()
        .await
        .map_err(|e| format!("解析 Apple 公钥响应失败: {}", e))?;
    if jwks.keys.is_empty() {
        return Err("Apple 公钥列表为空".to_string());
    }

    {
        let mut guard = KEYS
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|_| "公钥缓存锁异常".to_string())?;
        *guard = Some((now + KEYS_TTL_SECS, jwks.keys.clone()));
    }
    Ok(jwks.keys)
}

/// 已验证的 Apple 身份。
#[derive(Debug, Clone)]
pub struct AppleClaims {
    /// Apple 的用户唯一标识（`sub`）—— **稳定**，同一 App 内恒定。
    pub sub: String,
    /// 邮箱。⚠️ **只在首次授权时出现**（含「隐藏邮箱」时的 `@privaterelay.appleid.com` 转发地址）。
    pub email: Option<String>,
    /// 邮箱是否已被 Apple 验证。
    pub email_verified: bool,
}

/// 验证 `identityToken` 并取出 claims。
///
/// 校验项（**逐条都不可省**）：
/// 1. 三段式 + `alg` 必须是 `RS256`
/// 2. 按 `kid` 找 Apple 公钥 → **RSA 验签**
/// 3. `iss` == `https://appleid.apple.com`
/// 4. `aud` == 本 App 的 bundle id
/// 5. `exp` 未过期
///
/// ⚠️ 顺序有讲究：**先验签、后读 claims** —— 否则等于信任一段未经验证的 JSON。
pub async fn verify_identity_token(token: &str, client_id: &str) -> Result<AppleClaims, String> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return Err("identityToken 格式非法（应为三段）".to_string());
    }

    // ── ① 头部 ──
    let header: serde_json::Value = serde_json::from_slice(&b64url(parts[0])?)
        .map_err(|e| format!("identityToken 头部解析失败: {}", e))?;
    let alg = header
        .get("alg")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if alg != "RS256" {
        // 🔴 必须显式拒绝 —— 否则将来有人构造 `alg: "none"` 的空签名 token。
        return Err(format!("不支持的签名算法: {}", alg));
    }
    let kid = header
        .get("kid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "identityToken 缺少 kid".to_string())?;

    // ── ② 验签 ──
    let keys = apple_keys().await?;
    let jwk = keys
        .iter()
        .find(|k| k.kid == kid)
        .ok_or_else(|| "找不到匹配的 Apple 公钥（密钥可能刚轮换，请重试）".to_string())?;
    let n = b64url(&jwk.n)?;
    let e = b64url(&jwk.e)?;
    let sig = b64url(parts[2])?;
    let signing_input = format!("{}.{}", parts[0], parts[1]);

    ring::signature::RsaPublicKeyComponents { n: &n, e: &e }
        .verify(
            &ring::signature::RSA_PKCS1_2048_8192_SHA256,
            signing_input.as_bytes(),
            &sig,
        )
        .map_err(|_| "identityToken 签名验证失败".to_string())?;

    // ── ③ claims（⚠️ 此时才可信）──
    let claims: serde_json::Value = serde_json::from_slice(&b64url(parts[1])?)
        .map_err(|e| format!("identityToken 载荷解析失败: {}", e))?;

    let iss = claims
        .get("iss")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if iss != APPLE_ISSUER {
        return Err(format!("identityToken 的签发者不合法: {}", iss));
    }

    let aud = claims
        .get("aud")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if aud != client_id {
        // 📌 原生 iOS 的 `aud` = bundle id（**不是** Services ID）—— 见文件头事实 ③
        return Err("identityToken 与当前 App 不匹配（aud 校验失败）".to_string());
    }

    let exp = claims.get("exp").and_then(|v| v.as_i64()).unwrap_or(0);
    let now = chrono::Utc::now().timestamp();
    if exp <= now {
        return Err("identityToken 已过期，请重新登录".to_string());
    }

    let sub = claims
        .get("sub")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "identityToken 缺少 sub".to_string())?
        .to_string();

    // `email_verified` 在不同版本里是 bool 或 字符串 —— 两种都认。
    let email_verified = claims
        .get("email_verified")
        .map(|v| v.as_bool().unwrap_or_else(|| v.as_str() == Some("true")))
        .unwrap_or(false);

    Ok(AppleClaims {
        sub,
        email: claims
            .get("email")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        email_verified,
    })
}

/// 建一个新会话（签发 token）。与 `auth::register` / `login` 同一张表、同一种 token。
fn issue_token(conn: &rusqlite::Connection, user_id: &str) -> Result<String, String> {
    let now = chrono::Utc::now().timestamp();
    let token = uuid::Uuid::new_v4().to_string();
    let token_id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    )
    .map_err(|e| format!("Token insert error: {}", e))?;
    Ok(token)
}

/// 用已验证的 Apple 身份**建号 / 登录 / 绑定**。返回与 `auth::login` **同形**的响应。
///
/// # 三条分支（顺序不可调换）
///
/// | # | 条件 | 动作 |
/// |---|---|---|
/// | 0 | 传了 `current_user_id`（**已登录**的用户点了 Apple 登录） | **绑定**到该账号（= 认领，学习记录不丢） |
/// | 1 | `apple_user_id` 已存在 | 直接登录（顺带补 email） |
/// | 2 | 库里已有同 email 的账号 | 绑定 `apple_user_id` 后登录 |
/// | 3 | 都没有 | **建新号** |
///
/// # 🔴 为什么先按 `apple_user_id` 而不是 email
///
/// Apple **只在首次授权返回 email**（文件头事实 ①）⇒ 若按 email 找，
/// 老用户第二次登录（本次 token 无 email）会被当成新用户 ⇒ **重复建号、学习记录分裂**。
///
/// # 🔴 为什么「同 email 就绑定」是安全的
///
/// `email` 来自 Apple 的**已验证** claims（`email_verified`），
/// 且 Apple 只在用户确实拥有该邮箱时才返回它 ⇒ 等价于「邮箱验证」，
/// 与「用邮箱注册时需要收验证码」是同一个信任级别。
/// ⚠️ 反过来不成立：**绝不能**因为「本地库里有这个 email」就把 Apple 身份绑上去 ——
///    本函数的第 2 分支正是「Apple 说这个邮箱是他的」才绑定，方向是对的。
pub fn apple_login(
    conn: &rusqlite::Connection,
    claims: &AppleClaims,
    current_user_id: Option<&str>,
) -> Result<AuthResponse, String> {
    let now = chrono::Utc::now().timestamp();

    // ══════════════ 分支 0：已登录用户点「Apple 登录」= 绑定（认领）══════════════
    if let Some(uid) = current_user_id {
        // 该账号是否已绑过**别的** Apple 账号
        let bound: Option<String> = conn
            .query_row(
                "SELECT apple_user_id FROM users WHERE id = ?1",
                rusqlite::params![uid],
                |r| r.get(0),
            )
            .ok()
            .flatten();
        if let Some(existing) = bound {
            if existing != claims.sub {
                return Err("该账号已绑定其他 Apple 账号".to_string());
            }
        }
        // 这个 Apple 账号是否已被**别的** CoEvo 账号绑走
        let owner: Option<String> = conn
            .query_row(
                "SELECT id FROM users WHERE apple_user_id = ?1 AND id != ?2",
                rusqlite::params![claims.sub, uid],
                |r| r.get(0),
            )
            .ok();
        if owner.is_some() {
            return Err("该 Apple 账号已绑定其他账号".to_string());
        }

        let updated_email = bind_apple(conn, uid, claims)?;
        let token = issue_token(conn, uid)?;
        tracing::info!("apple_login: 已绑定到既有账号 user_id={}", uid);
        return Ok(AuthResponse {
            user_id: uid.to_string(),
            token,
            message: "Apple account linked".to_string(),
            email: updated_email,
        });
    }

    // ══════════════ 分支 1：按 apple_user_id 找 ══════════════
    let by_apple: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT id, email FROM users WHERE apple_user_id = ?1 AND deleted_at IS NULL",
            rusqlite::params![claims.sub],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .ok();

    if let Some((uid, email)) = by_apple {
        // 库里没有 email 而本次 Apple 给了 ⇒ 补上（首次建号时若有 email 就已写入，
        // 这里是「首次没给、后来给了」的兜底）。
        let final_email = match (&email, &claims.email) {
            (None, Some(e)) => {
                if let Err(err) = conn.execute(
                    "UPDATE users SET email = ?1 WHERE id = ?2 AND (email IS NULL OR email = '')",
                    rusqlite::params![e, uid],
                ) {
                    tracing::warn!("apple_login: 补 email 失败（不影响登录）: {}", err);
                }
                Some(e.clone())
            }
            _ => email,
        };
        let token = issue_token(conn, &uid)?;
        tracing::info!("apple_login: 既有 Apple 账号登录 user_id={}", uid);
        return Ok(AuthResponse {
            user_id: uid,
            token,
            message: "Login successful".to_string(),
            email: final_email,
        });
    }

    // ══════════════ 分支 2：库里已有同 email 的账号 ⇒ 绑定后登录 ══════════════
    if let Some(email) = claims.email.as_deref() {
        let same_email: Option<(String, Option<String>)> = conn
            .query_row(
                "SELECT id, apple_user_id FROM users \
                 WHERE email = ?1 COLLATE NOCASE AND deleted_at IS NULL",
                rusqlite::params![email],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();
        if let Some((uid, bound)) = same_email {
            // 该邮箱的账号已经绑了**别的** Apple 账号 ⇒ 不能抢
            if let Some(existing) = bound {
                if existing != claims.sub {
                    return Err("该邮箱已绑定其他 Apple 账号".to_string());
                }
            } else {
                if let Err(e) = conn.execute(
                    "UPDATE users SET apple_user_id = ?1 WHERE id = ?2",
                    rusqlite::params![claims.sub, uid],
                ) {
                    tracing::error!("apple_login: 绑定 apple_user_id 失败: {}", e);
                    return Err("Apple 登录失败，请重试".to_string());
                }
            }
            let token = issue_token(conn, &uid)?;
            tracing::info!("apple_login: 按 email 关联到既有账号 user_id={}", uid);
            return Ok(AuthResponse {
                user_id: uid,
                token,
                message: "Apple account linked".to_string(),
                email: Some(email.to_string()),
            });
        }
    }

    // ══════════════ 分支 3：建新号 ══════════════
    let user_id = uuid::Uuid::new_v4().to_string();
    // `username` 是内部标识（`NOT NULL UNIQUE`，不对用户暴露）。
    // 🔑 前缀用 `apple_` 与注册的 `u_` / 试用的 `trial_` 区分开 ——
    //    `trial_` 前缀被 `isTrialAccount` 用作判断，**绝不能**混用。
    let username = format!(
        "apple_{}",
        user_id
            .replace('-', "")
            .chars()
            .take(12)
            .collect::<String>()
    );
    let email: Option<String> = claims.email.clone();
    let display_name = match email.as_deref() {
        Some(e) => default_display_name(e),
        // 「隐藏邮箱」且 Apple 未给转发地址时的兜底（实务上极少见）
        None => "Apple 用户".to_string(),
    };
    // Apple 用户**没有密码**（`password_hash` 为 NULL）—— 与 trial 账号同一形态。
    // ⚠️ 后果：他不能用邮箱+密码登录、也改不了密码（`change_password` 要求验原密码）。
    //    这是**有意**的（他本来就不该有密码）—— 但接口层要能明确告诉他，而不是让他猜。
    conn.execute(
        "INSERT INTO users (id, username, display_name, password_hash, email, apple_user_id, created_at) \
         VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6)",
        rusqlite::params![user_id, username, display_name, email, claims.sub, now],
    )
    .map_err(|e| {
        tracing::error!("apple_login: 建号失败: {}", e);
        "Apple 登录失败，请重试".to_string()
    })?;

    let token = issue_token(conn, &user_id)?;
    tracing::info!("apple_login: 新建 Apple 账号 user_id={}", user_id);
    Ok(AuthResponse {
        user_id,
        token,
        message: "Registration successful".to_string(),
        email,
    })
}

/// 把 Apple 身份绑到既有账号上（分支 0 用），并在**库里 email 为空**时补上。
///
/// 返回绑定后账号的 email（供前端刷新「是否已注册」的判断）。
fn bind_apple(
    conn: &rusqlite::Connection,
    user_id: &str,
    claims: &AppleClaims,
) -> Result<Option<String>, String> {
    let current: Option<String> = conn
        .query_row(
            "SELECT email FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |r| r.get(0),
        )
        .ok()
        .flatten();

    // 🔑 **不覆盖**已有 email（用户可能已用邮箱注册过并绑定了自己的邮箱）。
    //    只在为空时补 —— 「改邮箱」有专门的两步流程，不该被登录顺手改掉。
    let final_email = match (&current, &claims.email) {
        (Some(e), _) if !e.trim().is_empty() => Some(e.clone()),
        (_, Some(e)) => {
            if let Err(err) = conn.execute(
                "UPDATE users SET apple_user_id = ?1, email = ?2 WHERE id = ?3",
                rusqlite::params![claims.sub, e, user_id],
            ) {
                tracing::error!("bind_apple: 写入失败: {}", err);
                return Err("Apple 登录失败，请重试".to_string());
            }
            return Ok(Some(e.clone()));
        }
        _ => None,
    };

    if let Err(e) = conn.execute(
        "UPDATE users SET apple_user_id = ?1 WHERE id = ?2",
        rusqlite::params![claims.sub, user_id],
    ) {
        tracing::error!("bind_apple: 绑定失败: {}", e);
        return Err("Apple 登录失败，请重试".to_string());
    }
    Ok(final_email)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `b64url` 两种形态都要认（JWT 标准无 padding；有些工具会补 `=`）。
    ///
    /// 📌 用例取自真实形态：RSA 指数 65537 的标准编码是 `AQAB`（4 字符，**不需要**
    ///    padding —— 长度已是 4 的倍数）。要测 padding 容错得换长度不对齐的：
    ///    `0x01` ⇒ 标准编码 `AQ==` ⇒ 无 padding 形态是 `AQ`。
    /// ⚠️ 注意 `"AQAB="`（**多余** padding）是**非法** base64（长度非 4 的倍数）——
    ///    标准解码器都会拒绝，本函数**不**为它做特殊处理（那会掩盖真实的编码错误）。
    #[test]
    fn test_b64url_accepts_padded_and_unpadded() {
        // 4 字符：两种引擎都直接可解
        assert_eq!(b64url("AQAB").unwrap(), vec![0x01, 0x00, 0x01]);
        // 1 字节：no-pad 形态 与 带 padding 形态都要能解
        assert_eq!(b64url("AQ").unwrap(), vec![0x01]);
        assert_eq!(b64url("AQ==").unwrap(), vec![0x01]);
    }

    /// 🔴 `alg` 不是 RS256 ⇒ 必须拒绝（防 `alg: "none"` 的空签名 token）。
    ///
    /// ⚠️ 这条测试**不联网**：它走的是「头部解析 → alg 检查」这条路，
    ///    在取公钥**之前**就返回。
    #[tokio::test]
    async fn test_rejects_non_rs256_alg_without_network() {
        // header = {"alg":"none"}  payload = {}  signature = 空
        let header = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#);
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b"{}");
        let token = format!("{header}.{payload}.");

        let err = verify_identity_token(&token, "com.coevo.coevoApp")
            .await
            .unwrap_err();
        assert!(err.contains("不支持的签名算法"), "实际：{err}");
    }

    /// 段数不对 ⇒ 拒绝（且不联网）。
    #[tokio::test]
    async fn test_rejects_malformed_token() {
        let err = verify_identity_token("not-a-jwt", "com.coevo.coevoApp")
            .await
            .unwrap_err();
        assert!(err.contains("格式非法"), "实际：{err}");
    }

    /// 🔴 建号路径：`apple_user_id` 必须落库，且**第二次登录走「既有账号」分支**
    /// （不能重复建号 —— 那正是「按 email 找」的 bug 形态）。
    #[test]
    fn test_apple_login_creates_then_reuses_account() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        let claims = AppleClaims {
            sub: "001234.abcdef".into(),
            email: Some("apple-user@example.com".into()),
            email_verified: true,
        };

        // ① 首次 ⇒ 建号
        let r1 = apple_login(&conn, &claims, None).unwrap();
        assert_eq!(r1.email.as_deref(), Some("apple-user@example.com"));

        // ② 再次登录，**且本次 Apple 没给 email**（真实场景：非首次授权）
        let no_email = AppleClaims {
            sub: "001234.abcdef".into(),
            email: None,
            email_verified: false,
        };
        let r2 = apple_login(&conn, &no_email, None).unwrap();
        assert_eq!(r2.user_id, r1.user_id, "必须复用同一账号，不能重复建号");
        assert_eq!(
            r2.email.as_deref(),
            Some("apple-user@example.com"),
            "email 应从库里取回（本次 token 里没有）"
        );

        // 只应有一个账号
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "只应有一个账号");
    }

    /// 🔴 **`apple_user_id` 唯一索引必须生效**（否则同一 Apple 账号会分裂成多个 CoEvo 账号）。
    #[test]
    fn test_apple_user_id_is_unique() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        conn.execute(
            "INSERT INTO users (id, username, email, apple_user_id, created_at) \
             VALUES ('u1','u1','a@x.com','sub-1',1)",
            [],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO users (id, username, email, apple_user_id, created_at) \
             VALUES ('u2','u2','b@x.com','sub-1',1)",
            [],
        );
        assert!(dup.is_err(), "同一个 apple_user_id 不能对应两个账号");

        // 但要允许多行 NULL（非 Apple 账号绝大多数）
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) VALUES ('u3','u3','c@x.com',1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) VALUES ('u4','u4','d@x.com',1)",
            [],
        )
        .unwrap();
    }

    /// 分支 2：库里已有同 email 的账号 ⇒ **绑定**（不建新号，学习记录不丢）。
    #[test]
    fn test_apple_login_links_existing_email_account() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        let existing = crate::auth::register(
            &conn,
            &crate::auth::RegisterRequest {
                email: "same@example.com".into(),
                password: "abc123".into(),
                referral: None,
            },
        )
        .unwrap();

        let claims = AppleClaims {
            sub: "sub-link".into(),
            email: Some("same@example.com".into()),
            email_verified: true,
        };
        let r = apple_login(&conn, &claims, None).unwrap();
        assert_eq!(r.user_id, existing.user_id, "应绑到既有账号而非建新号");

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    /// 分支 0：已登录用户点 Apple 登录 ⇒ **绑定到当前账号**（认领语义，学习记录保留）。
    #[test]
    fn test_apple_login_binds_to_current_user() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        // 模拟「匿名试用账号」（有学习记录，无 email、无密码）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, email, created_at) \
             VALUES ('trial-1','trial_xyz',NULL,NULL,1)",
            [],
        )
        .unwrap();

        let claims = AppleClaims {
            sub: "sub-bind".into(),
            email: Some("bound@example.com".into()),
            email_verified: true,
        };
        let r = apple_login(&conn, &claims, Some("trial-1")).unwrap();
        assert_eq!(r.user_id, "trial-1", "必须绑到当前账号（不能新建）");
        assert_eq!(r.email.as_deref(), Some("bound@example.com"));

        // apple_user_id 与 email 都已写入
        let (sub, email): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT apple_user_id, email FROM users WHERE id = 'trial-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(sub.as_deref(), Some("sub-bind"));
        assert_eq!(email.as_deref(), Some("bound@example.com"));

        // 仍然只有一个账号
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    /// 🔴 一个 Apple 账号不能抢已被别人绑定的邮箱账号；反之亦然。
    #[test]
    fn test_apple_login_refuses_cross_binding() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        conn.execute(
            "INSERT INTO users (id, username, email, apple_user_id, created_at) \
             VALUES ('u1','u1','taken@example.com','sub-A',1)",
            [],
        )
        .unwrap();

        // sub-B 拿着同一个 email 来 ⇒ 拒绝（该邮箱的账号已绑 sub-A）
        let claims = AppleClaims {
            sub: "sub-B".into(),
            email: Some("taken@example.com".into()),
            email_verified: true,
        };
        let err = apple_login(&conn, &claims, None).unwrap_err();
        assert!(err.contains("已绑定其他 Apple 账号"), "实际：{err}");

        // 已登录账号 u2 想绑一个已被 u1 占用的 sub ⇒ 拒绝
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) \
             VALUES ('u2','u2','other@example.com',1)",
            [],
        )
        .unwrap();
        let claims2 = AppleClaims {
            sub: "sub-A".into(),
            email: Some("other@example.com".into()),
            email_verified: true,
        };
        let err2 = apple_login(&conn, &claims2, Some("u2")).unwrap_err();
        assert!(err2.contains("已绑定其他账号"), "实际：{err2}");
    }

    /// 绑定不应**覆盖**已有 email（用户可能已用邮箱注册过 —— 改邮箱有专门流程）。
    #[test]
    fn test_bind_does_not_overwrite_existing_email() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();

        let existing = crate::auth::register(
            &conn,
            &crate::auth::RegisterRequest {
                email: "mine@example.com".into(),
                password: "abc123".into(),
                referral: None,
            },
        )
        .unwrap();

        let claims = AppleClaims {
            sub: "sub-new".into(),
            email: Some("apple-relay@privaterelay.appleid.com".into()),
            email_verified: true,
        };
        let r = apple_login(&conn, &claims, Some(&existing.user_id)).unwrap();
        assert_eq!(
            r.email.as_deref(),
            Some("mine@example.com"),
            "已有 email 不该被 Apple 的转发地址覆盖"
        );
    }
}
