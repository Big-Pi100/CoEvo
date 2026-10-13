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
//! # 🆕 2026-10-13：注销时撤销 Apple 授权（原「有意不做」的第 2 条，现已实施）
//!
//! Apple 审核 5.1.1(v)：用户**删除账号**时，若该账号用过 Sign in with Apple，
//! **必须同时向 Apple 撤销授权**（`POST https://appleid.apple.com/auth/revoke`）。
//!
//! ## 🔴 唯一的时机是「登录那一刻」
//!
//! 撤销需要 `refresh_token`，而它**只能由 `authorizationCode` 换得** ——
//! 而 `authorizationCode` **只在用户登录成功那一刻由 Apple 返回**，事后拿不到、也补不了。
//! ⇒ 必须在登录时**顺手存下来**（`users.apple_refresh_token`，AES-GCM 加密）。
//!    **晚一天再补 = 那一天之前登录过的用户永久撤不了。**
//!
//! ## 三个动作
//!
//! | # | 时机 | 函数 |
//! |---|---|---|
//! | ① | 登录成功（客户端带了 code）| [`exchange_authorization_code`] → [`store_refresh_token`] |
//! | ② | 用户注销 | [`revoke_refresh_token`]（**尽力而为**：失败**不得**阻断注销）|
//! | ③ | 生成 `client_secret` | [`client_secret`]（`.p8` + Team ID + Key ID 签 ES256 JWT）|
//!
//! ## ⚠️ 三个易错点（都会表现为同一种 `invalid_client`，看不出病因）
//!
//! | 坑 | 说明 |
//! |---|---|
//! | `client_secret` 的签名必须是 **P-1363 的 `r + s`（64 字节）**，不是 ASN.1 DER | 用错格式 ⇒ 签名"成功"但 Apple 一律拒 |
//! | `.p8` 必须是 **勾了 `Sign in with Apple` 的那把 Key** | 与 ASC API Key（出包上传）/ IAP Key（查购买）**互不通用** |
//! | `authorizationCode` **只能用一次**、约 5 分钟过期 | ⇒ 「登录时存」是唯一解，不能攒着晚点换 |
//!
//! # ⚠️ 本模块**有意不做**的一件事（如实标注）
//!
//! | 事项 | 为什么不做 | 何时要补 |
//! |---|---|---|
//! | **nonce 校验** | 需要在「发 nonce」与「验 nonce」之间共享状态（防重放）。当前 `identityToken` 有效期仅约 10 分钟、且经 HTTPS 传输 | 若将来接入 Web 端（重放面变大）或出现可疑登录 |

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

// ══════════════════════════════════════════════════════════════════════════
// 注销撤销 Apple 授权所需：client_secret / 换 token / 撤销
// ══════════════════════════════════════════════════════════════════════════

/// Apple 的 token 端点（`authorization_code` → refresh token）。
const APPLE_TOKEN_URL: &str = "https://appleid.apple.com/auth/token";
/// Apple 的撤销端点。
const APPLE_REVOKE_URL: &str = "https://appleid.apple.com/auth/revoke";

/// `client_secret` 的有效期 —— Apple **硬上限 6 个月**（≈ 182.5 天）。
///
/// ⚠️ 超了 Apple 直接拒（`invalid_client`），而错误信息**不会**告诉你是有效期问题。
/// 我们每次调用都现签（不缓存），所以这里给到上限即可。
const CLIENT_SECRET_TTL_SECS: i64 = 15_777_000;

/// 读一个**必需**的环境变量（空串视为未设置）。
fn env_required(key: &str) -> Result<String, String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("缺少环境变量 {}（撤销 Apple 授权必需）", key))
}

/// 把 `.p8`（PKCS#8 PEM）解成 DER。
///
/// 🔑 只剥 `-----` 行、忽略空行 —— **不**假设 base64 的换行宽度
///    （Apple 的 `.p8` 是 64 列，但任何宽度都应能解）。
///
/// # 🔑 两种「换行形态」都要认（2026-10-13 加固）
///
/// 环境变量里的 PEM 可能以**两种**形态出现，取决于怎么写进 `.env`：
///
/// | 形态 | 样子 |
/// |---|---|
/// | ① 真实多行（systemd `EnvironmentFile` 的跨行引号值）| `...BEGIN...\nMIGT...\n...END..."` |
/// | ② **压成一行、用 `\n` 转义**（某些面板 / CLI 粘贴会这样）| `"-----BEGIN...\\nMIGT...\\n-----END..."` |
///
/// 形态 ② 下若不做归一化，整串只有一个 `lines()` 元素、且以 `-----` 开头
/// ⇒ 会被当成「PEM 头尾行」全部滤掉 ⇒ 报「私钥 PEM 为空」。
/// 📌 不做归一化也能被发现（有明确报错），但**在部署后才发现**成本高得多
///    —— 那时候排查方向会先怀疑「密钥是不是错了」。
fn pem_pkcs8_der(pem: &str) -> Result<Vec<u8>, String> {
    use base64::engine::general_purpose::STANDARD;
    // 归一化：字面 `\n` → 真换行；再去掉 `\r`（CRLF 文件）
    let normalized = pem.replace("\\n", "\n").replace('\r', "");
    let body: String = normalized
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("-----"))
        .collect();
    if body.is_empty() {
        return Err("Apple 私钥 PEM 为空".to_string());
    }
    STANDARD
        .decode(body.as_bytes())
        .map_err(|e| format!("Apple 私钥 PEM 解析失败: {}", e))
}

/// 生成 Apple 的 `client_secret`（一个 **ES256** 签名的 JWT）。
///
/// # 🔴 为什么必须用 `ECDSA_P256_SHA256_FIXED_SIGNING`
///
/// JWS 的 `ES256` 要求签名是 **IEEE P-1363 的 `r + s`（64 字节定长）**。
/// ring 里另有 `..._ASN1_SIGNING`（DER 包装，长度可变）—— 用它签名**本地不会报错**，
/// 但 Apple 一律回 `invalid_client`，且**从错误里看不出是格式问题**。
///
/// 📌 单测 `test_client_secret_is_verifiable_es256_jwt` 直接断言「签名长度 == 64」
///    并用公钥真验签 —— 换错算法会立刻红。
fn build_client_secret(
    team_id: &str,
    key_id: &str,
    client_id: &str,
    p8_pem: &str,
    now: i64,
) -> Result<String, String> {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

    let der = pem_pkcs8_der(p8_pem)?;
    let rng = SystemRandom::new();
    let kp = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
        .map_err(|e| format!("Apple 私钥不可用（.p8 格式或曲线不对）: {}", e))?;

    let header = serde_json::json!({"alg": "ES256", "kid": key_id, "typ": "JWT"});
    let claims = serde_json::json!({
        "iss": team_id,
        "iat": now,
        "exp": now + CLIENT_SECRET_TTL_SECS,
        // `aud` 对 client_secret 固定是 Apple，**不是** bundle id（别与 identityToken 的 aud 混）
        "aud": APPLE_ISSUER,
        "sub": client_id,
    });

    let h = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).map_err(|e| e.to_string())?);
    let p = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).map_err(|e| e.to_string())?);
    let signing_input = format!("{}.{}", h, p);
    let sig = kp
        .sign(&rng, signing_input.as_bytes())
        .map_err(|e| format!("client_secret 签名失败: {}", e))?;

    Ok(format!(
        "{}.{}",
        signing_input,
        URL_SAFE_NO_PAD.encode(sig.as_ref())
    ))
}

/// 从环境读凭据并现签一个 `client_secret`。
///
/// 环境变量：`APPLE_TEAM_ID` · `APPLE_KEY_ID` · `APPLE_PRIVATE_KEY`（`.p8` 原文，可多行）。
/// 🔴 必须是 **`Sign in with Apple` 专用的那把 Key** ——
///    与 `IAP_*`（查购买）/ CI 的 ASC API Key **不能混用**。
pub fn client_secret() -> Result<String, String> {
    let team_id = env_required("APPLE_TEAM_ID")?;
    let key_id = env_required("APPLE_KEY_ID")?;
    let pem = env_required("APPLE_PRIVATE_KEY")?;
    build_client_secret(
        &team_id,
        &key_id,
        &apple_client_id(),
        &pem,
        chrono::Utc::now().timestamp(),
    )
}

/// Apple token / revoke 端点的响应（只取我们关心的字段）。
#[derive(Debug, Default, Deserialize)]
struct AppleTokenResponse {
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// 用 `authorizationCode` 换 `refresh_token`（**只能换一次**）。
///
/// ⚠️ code 由客户端在登录那一刻取得 ⇒ 本函数必须在登录请求的**同一条链路**里立刻调用
///    （Apple 侧约 5 分钟过期）。
pub async fn exchange_authorization_code(code: &str) -> Result<String, String> {
    let client_id = apple_client_id();
    let secret = client_secret()?;

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("构建 HTTP 客户端失败: {}", e))?;
    let resp = client
        .post(APPLE_TOKEN_URL)
        .form(&[
            ("client_id", client_id.as_str()),
            ("client_secret", secret.as_str()),
            ("code", code),
            ("grant_type", "authorization_code"),
        ])
        .send()
        .await
        .map_err(|e| format!("换取 Apple refresh token 失败: {}", e))?;

    let status = resp.status();
    let body: AppleTokenResponse = resp
        .json()
        .await
        .map_err(|e| format!("解析 Apple token 响应失败: {}", e))?;

    match body.refresh_token {
        Some(rt) if !rt.is_empty() => Ok(rt),
        _ => Err(format!(
            "Apple 未返回 refresh_token（HTTP {} · error={:?}）",
            status, body.error
        )),
    }
}

/// 向 Apple 撤销一个 refresh token（注销账号时调用）。
///
/// 🔴 **尽力而为**：调用方**不得**因它失败而阻断注销 ——
///    Apple 5.1.1(v) 要求「删除账号」是用户随时可完成的操作，
///    而撤销失败只影响「Apple 侧仍记着这次授权」，二者严重性不对等。
///    ⚠️ 但**必须记日志**，否则运维会以为「撤销成功」。
pub async fn revoke_refresh_token(refresh_token: &str) -> Result<(), String> {
    if refresh_token.trim().is_empty() {
        return Err("refresh token 为空".to_string());
    }
    let client_id = apple_client_id();
    let secret = client_secret()?;

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("构建 HTTP 客户端失败: {}", e))?;
    let resp = client
        .post(APPLE_REVOKE_URL)
        .form(&[
            ("client_id", client_id.as_str()),
            ("client_secret", secret.as_str()),
            ("token", refresh_token),
            ("token_type_hint", "refresh_token"),
        ])
        .send()
        .await
        .map_err(|e| format!("撤销 Apple 授权失败: {}", e))?;

    if resp.status().is_success() {
        return Ok(());
    }
    // Apple 的失败响应体里带 `error`（如 `invalid_grant`/`invalid_client`）
    let body: AppleTokenResponse = resp.json().await.unwrap_or_default();
    Err(format!("撤销 Apple 授权被拒（error={:?}）", body.error))
}

/// 把 refresh token **加密**后写进 `users.apple_refresh_token`。
///
/// 🔑 复用 `encryption`（AES-256-GCM，密钥来自 `COEVO_PII_KEY`）——
///    refresh token 是**长期凭据**，明文落库等于「拿库就能长期冒充用户」。
pub fn store_refresh_token(
    conn: &rusqlite::Connection,
    user_id: &str,
    refresh_token: &str,
) -> Result<(), String> {
    let enc = crate::encryption::encrypt(refresh_token);
    conn.execute(
        "UPDATE users SET apple_refresh_token = ?1 WHERE id = ?2",
        rusqlite::params![enc, user_id],
    )
    .map_err(|e| format!("保存 Apple refresh token 失败: {}", e))?;
    Ok(())
}

/// 取出并解密某账号的 Apple refresh token（无 / 解不出 ⇒ `None`）。
///
/// ⚠️ 解密失败返回 `None` 而**不是**空串 —— 调用方据此区分「没绑过 Apple」
///    与「有记录但解不开（密钥换了）」，前者静默、后者应记日志。
pub fn refresh_token_of(conn: &rusqlite::Connection, user_id: &str) -> Option<String> {
    let enc: Option<String> = conn
        .query_row(
            "SELECT apple_refresh_token FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |r| r.get(0),
        )
        .ok()
        .flatten();
    let enc = enc.filter(|s| !s.trim().is_empty())?;
    let dec = crate::encryption::decrypt(&enc);
    if dec.is_empty() {
        tracing::warn!(
            "apple refresh token 解不开（密钥换过？）uid={} —— 该用户注销时无法撤销 Apple 授权",
            user_id
        );
        return None;
    }
    Some(dec)
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

    // ══════════════════════════════════════════════════════════════════════
    // 2026-10-13：注销撤销 Apple 授权（client_secret / refresh token 存储）
    // ══════════════════════════════════════════════════════════════════════

    /// 把 DER 包成 PEM（测试用 —— 生产用的是 Apple 给的 `.p8`）。
    fn pem_from_der(der: &[u8]) -> String {
        use base64::engine::general_purpose::STANDARD;
        let b64 = STANDARD.encode(der);
        let mut out = String::from("-----BEGIN PRIVATE KEY-----\n");
        for chunk in b64.as_bytes().chunks(64) {
            out.push_str(std::str::from_utf8(chunk).unwrap());
            out.push('\n');
        }
        out.push_str("-----END PRIVATE KEY-----\n");
        out
    }

    /// 🔴 `client_secret` 必须是**能验签通过的 ES256 JWT**（Apple 的硬要求）。
    ///
    /// ⚠️ 本测试**不联网**：造一把 P-256 私钥 → 生成 → 本地验签 + 检查 claims。
    ///
    /// # 它守的是最容易错、且**最难从错误里看出来**的那一点
    ///
    /// JWS 的 `ES256` 要求签名是 **P-1363（`r + s`，定长 64 字节）**。
    /// ring 里另有 ASN.1 DER 版本 —— 用它签名**本地一切正常**，
    /// 但 Apple 一律回 `invalid_client`，且错误信息**完全看不出是格式问题**。
    /// ⇒ 下面那条「签名长度 == 64」是关键护栏（DER 版会是 70~72 字节）。
    #[test]
    fn test_client_secret_is_verifiable_es256_jwt() {
        use ring::rand::SystemRandom;
        use ring::signature::{
            EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING,
        };

        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let der = pkcs8.as_ref();
        let pem = pem_from_der(der);

        let now = 1_800_000_000i64;
        let jwt = build_client_secret("TEAM43MDWDA", "MTUH2XZUP5", "com.coevo.coevoApp", &pem, now)
            .unwrap();

        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "client_secret 必须是三段 JWT");

        let header: serde_json::Value = serde_json::from_slice(&b64url(parts[0]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "MTUH2XZUP5");
        assert_eq!(header["typ"], "JWT");

        let claims: serde_json::Value = serde_json::from_slice(&b64url(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iss"], "TEAM43MDWDA");
        assert_eq!(claims["sub"], "com.coevo.coevoApp");
        // 🔴 `aud` 固定是 Apple —— 与 `identityToken` 的 `aud`（= bundle id）**不是一回事**
        assert_eq!(claims["aud"], "https://appleid.apple.com");
        assert_eq!(claims["iat"].as_i64().unwrap(), now);
        assert_eq!(
            claims["exp"].as_i64().unwrap() - now,
            CLIENT_SECRET_TTL_SECS,
            "有效期必须 <= Apple 的 6 个月硬上限"
        );
        assert!(
            CLIENT_SECRET_TTL_SECS <= 15_777_000,
            "超过 6 个月 Apple 会拒（invalid_client，且看不出原因）"
        );

        let sig = b64url(parts[2]).unwrap();
        assert_eq!(
            sig.len(),
            64,
            "🔴 ES256 签名必须是 64 字节（P-1363 `r+s`）—— 若变成 70~72 就是误用了 ASN.1 DER 版本"
        );

        // 真验签：证明签名**有效**，不只是长度凑巧对
        let kp = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, der, &rng).unwrap();
        let pubkey = ring::signature::UnparsedPublicKey::new(
            &ECDSA_P256_SHA256_FIXED,
            kp.public_key().as_ref(),
        );
        pubkey
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &sig)
            .expect("client_secret 的签名必须能用自己的公钥验过");
    }

    /// 私钥不是合法 PEM ⇒ 明确报错（**不许**静默产出一个签不出名的 JWT）。
    #[test]
    fn test_client_secret_rejects_bad_pem() {
        let err = build_client_secret("T", "K", "c", "not-a-pem", 0).unwrap_err();
        assert!(err.contains("PEM"), "实际：{err}");
        let err2 = build_client_secret("T", "K", "c", "   \n  ", 0).unwrap_err();
        assert!(err2.contains("PEM"), "实际：{err2}");
    }

    /// 🔴 refresh token **必须密文落库** —— 它是长期凭据，明文等于「拿库就能长期冒充用户」。
    #[test]
    fn test_refresh_token_stored_encrypted_and_readable() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) VALUES ('u1','u1','u1@e.com',1)",
            [],
        )
        .unwrap();

        assert!(refresh_token_of(&conn, "u1").is_none(), "没绑过 ⇒ None");

        store_refresh_token(&conn, "u1", "RT-SECRET-VALUE").unwrap();

        let raw: String = conn
            .query_row(
                "SELECT apple_refresh_token FROM users WHERE id = 'u1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            !raw.contains("RT-SECRET-VALUE"),
            "refresh token 竟然明文落库: {raw}"
        );
        assert_eq!(
            refresh_token_of(&conn, "u1").as_deref(),
            Some("RT-SECRET-VALUE"),
            "存进去的要能原样取回（否则撤销会拿着乱码去请求）"
        );
    }

    /// 未绑过 Apple 的账号 ⇒ `None`（注销时不该去撤销一个不存在的授权）。
    #[test]
    fn test_refresh_token_of_unbound_is_none() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) VALUES ('u2','u2','u2@e.com',1)",
            [],
        )
        .unwrap();
        assert!(refresh_token_of(&conn, "u2").is_none());
        assert!(
            refresh_token_of(&conn, "不存在").is_none(),
            "查不到的 id 不该 panic"
        );
    }

    /// 🔴 PEM 的**两种换行形态**必须都能解（2026-10-13 加固）。
    ///
    /// | 形态 | 来源 |
    /// |---|---|
    /// | 真实多行 | systemd `EnvironmentFile` 的跨行引号值（生产 `.env` 就是这么存的）|
    /// | 单行 + `\n` 转义 | 某些面板 / CLI 粘贴会压成这种 |
    ///
    /// 🔑 不做归一化时形态 ② 会报「私钥 PEM 为空」—— 报错是对的，但**部署后才发现**，
    ///    而那时第一反应会是「密钥是不是错了」（排查方向被带偏）。
    /// ⇒ 单测直接断言两者产出**同一份 DER**。
    #[test]
    fn test_pem_accepts_multiline_and_escaped_newline_forms() {
        use ring::rand::SystemRandom;
        use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let der = pkcs8.as_ref().to_vec();

        let multiline = pem_from_der(&der);
        // 形态 ②：把真实换行替换成字面 `\n`
        let escaped = multiline.replace('\n', "\\n");
        assert!(!escaped.contains('\n'), "前提：形态②确实没有真实换行");

        let a = pem_pkcs8_der(&multiline).unwrap();
        let b = pem_pkcs8_der(&escaped).unwrap();
        assert_eq!(a, der, "形态①（真实多行）解出的 DER 应与原文一致");
        assert_eq!(b, der, "形态②（\\n 转义）必须解出同一份 DER");
    }
}
