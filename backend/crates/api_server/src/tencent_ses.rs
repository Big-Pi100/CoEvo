//! 腾讯云邮件推送（SES）—— 发送**验证码**（找回密码 / 修改邮箱 共用）
//!
//! # 🔴 三条硬性事实（都已核实，不要照旧教程做）
//!
//! | # | 事实 | 后果 |
//! |---|---|---|
//! | ① | 腾讯云**默认只允许模板发信**（自定义内容需特殊申请） | 只提供 [`send_verification_code`] 这类模板方法 |
//! | ② | 自 **2026-03-02** 起，新开通的**个人实名**用户**不支持 SMTP** | 只能走 API ⇒ 本项目本就用 API，无影响 |
//! | ③ | 国内站 SendEmail 的 **Version = `2020-10-02`** | 🔴 网上不少文章写 `2019-03-18`（那是国际站旧值）→ 用错会被判 `InvalidAction` |
//!
//! # 为什么用子域名 `mail.keyievolution.fun` 发信
//!
//! 腾讯云 SES 要求发信域名配 **MX**（接退信）。而主域名 `keyievolution.fun` 的 MX
//! 已被 Cloudflare Email Routing 占用（`support@` 靠它收信，那是隐私政策里公示的邮箱）。
//! ⇒ 把 SES 全部记录加在 **`mail.` 子域名**上，主域名 MX/SPF 一个字不动。
//! 📄 详见 `docs/operations/tencent-ses-onboarding-2026-10-05.md`。
//!
//! # 为什么密钥**不复用** ASR 的那一对
//!
//! ASR 用 `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY`；本模块用独立的
//! `TENCENT_SES_*`。原因：**最小权限** —— SES 侧用只授 `ses:SendEmail` 的子账号，
//! 即使服务器被入侵导致这对密钥泄露，攻击者也**发不了别的服务**，
//! 且不影响 ASR 的那对。

use crate::tencent_sign::{call, Tc3Call};

const SERVICE: &str = "ses";
const HOST: &str = "ses.tencentcloudapi.com";
const ACTION: &str = "SendEmail";
/// 国内站 API 版本（见文件头事实 ③）。
const VERSION: &str = "2020-10-02";
/// 邮件主题。腾讯云要求 `Subject` **必填**（即使走模板）。
///
/// 🔴 **2026-10-07 改为中性文案**（原为「CoEvo 密码重置验证码」）。
///
/// 原因：**修改邮箱**功能复用了同一条发送通道。若主题仍写着「密码重置」，
/// 用户在做「改邮箱」时会收到一封标题为**密码重置**的邮件 ⇒ 误导，
/// 且会让人以为「账号被盗、有人在重置我的密码」（**安全恐慌**）。
///
/// 📌 判据：**复用发送通道时，「收件人看到什么」必须一并中性化或区分** ——
///    主题与正文都是「用户读到的语义」，它们和「用哪个 API 发」是两回事。
/// ⚠️ 腾讯云控制台的**模板正文**也要同步中性化（那是我们改不了的另一半），
///    见 `docs/operations/tencent-ses-onboarding-2026-10-05.md` 的「模板正文」小节。
const SUBJECT: &str = "记忆之书 验证码";

/// SES 配置（全部来自环境变量，**不落盘到仓库**）。
pub struct SesConfig {
    secret_id: String,
    secret_key: String,
    /// 发信地址，可带显示名，形如 `CoEvo <noreply@mail.keyievolution.fun>`。
    from: String,
    /// 模板 ID（腾讯云控制台的数字 ID）。
    template_id: String,
    region: String,
    /// 回复地址 —— 用户直接按「回复」时能到达我们能收的邮箱。
    reply_to: String,
}

impl SesConfig {
    /// 从进程环境读取。任一项缺失/为空 → `None`（视作「未配置」）。
    pub fn from_env() -> Option<Self> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// 🔑 抽成接受一个查找函数的形式，使「配置解析」可以被单测覆盖
    /// （否则测试只能改进程环境变量 —— 那会与并行测试互相干扰）。
    fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let secret_id = get("TENCENT_SES_SECRET_ID")?;
        let secret_key = get("TENCENT_SES_SECRET_KEY")?;
        let from = get("TENCENT_SES_FROM")?;
        let template_id = get("TENCENT_SES_TEMPLATE_ID")?;
        if [&secret_id, &secret_key, &from, &template_id]
            .iter()
            .any(|s| s.is_empty())
        {
            return None;
        }
        Some(Self {
            secret_id,
            secret_key,
            from,
            template_id,
            region: get("TENCENT_SES_REGION").unwrap_or_else(|| "ap-guangzhou".to_string()),
            reply_to: get("TENCENT_SES_REPLY_TO")
                .unwrap_or_else(|| "support@keyievolution.fun".to_string()),
        })
    }
}

/// 构造 SendEmail 的请求体（**纯函数** —— 不碰网络、不读环境）。
///
/// 🔑 抽出来是为了让「请求体形态」被**断言**覆盖，而不是靠人肉读代码：
///    `TemplateData` 必须是 **JSON 字符串**（不是嵌套对象）是这里最容易错的一点。
fn build_body(cfg: &SesConfig, to: &str, code: &str) -> Result<String, String> {
    // 🔴 `TemplateData` 是 **JSON 字符串**（不是对象）——
    //    腾讯云原文：「请使用 json.dump 将 json 对象格式化成 string 类型」。
    //    传成嵌套对象会被判 `3010 The format of the TemplateData field is incorrect`。
    let template_data = serde_json::json!({ "code": code }).to_string();

    let template_id: u64 = cfg
        .template_id
        .parse()
        .map_err(|_| "TENCENT_SES_TEMPLATE_ID 非法（应为纯数字）".to_string())?;

    let body = serde_json::json!({
        "FromEmailAddress": &cfg.from,
        "ReplyToAddresses": &cfg.reply_to,
        "Destination": [to],
        "Subject": SUBJECT,
        "Template": {
            "TemplateID": template_id,
            "TemplateData": template_data,
        }
    });

    serde_json::to_string(&body).map_err(|e| format!("json: {}", e))
}

/// 发送**验证码**邮件。成功返回 `Ok(())`。
///
/// # 两个调用方（同一条通道、同一份文案）
///
/// | 场景 | 收件人 | 调用方 |
/// |---|---|---|
/// | 忘记密码 | 用户**自己的**已注册邮箱 | `routes::auth_forgot_password` |
/// | 修改邮箱 | 用户想**换成**的新邮箱 | `routes::auth_change_email_code` |
///
/// 🔴 **2026-10-07 由 `send_reset_code` 改名** —— 原名只说出了第一个场景，
///    第二个场景接进来后名字就与用途不符了（语义残留会误导后来者以为不能复用）。
///
/// ⚠️ **未配置**时返回 `Err("邮件服务未配置")` —— 调用方（路由层）应把它转成
/// 用户可读的「验证码发送失败，请稍后再试」，**不要**把内部细节透给前端。
///
/// 🔴 失败必须**如实**返回：若这里把 `Err` 吞掉，用户会一直等一封永远不来的验证码
///    （「静默失效」—— 本项目的主要敌人）。
pub async fn send_verification_code(to: &str, code: &str) -> Result<(), String> {
    let cfg = SesConfig::from_env().ok_or_else(|| "邮件服务未配置".to_string())?;
    let body = build_body(&cfg, to, code)?;

    let resp = call(Tc3Call {
        service: SERVICE,
        host: HOST,
        action: ACTION,
        version: VERSION,
        region: &cfg.region,
        secret_id: &cfg.secret_id,
        secret_key: &cfg.secret_key,
        body: &body,
    })
    .await?;

    // 成功时腾讯云回 `{"Response":{"RequestId":..,"MessageId":..}}`。
    // ⚠️ `MessageId` 只是「已受理」，不代表已送达 —— 真正的投递状态查 `GetSendEmailStatus`。
    //    这里不额外查询：对「发验证码」而言，受理即够（送达失败会进退信统计）。
    let message_id = resp
        .get("MessageId")
        .and_then(|v| v.as_str())
        .unwrap_or("(无)");
    tracing::info!("SES 验证码邮件已提交：message_id={}", message_id);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg_with(template_id: &str) -> SesConfig {
        SesConfig {
            secret_id: "id".into(),
            secret_key: "key".into(),
            from: "CoEvo <noreply@mail.keyievolution.fun>".into(),
            template_id: template_id.into(),
            region: "ap-guangzhou".into(),
            reply_to: "support@keyievolution.fun".into(),
        }
    }

    /// 🔴 本模块最容易错的一点：`TemplateData` 必须是 **JSON 字符串**。
    ///    传成嵌套对象 → 腾讯云判 `3010 format incorrect`，且**看起来像配置问题**。
    #[test]
    fn test_template_data_is_json_string_not_object() {
        let body: serde_json::Value =
            serde_json::from_str(&build_body(&cfg_with("123456"), "a@b.com", "654321").unwrap())
                .unwrap();

        let td = &body["Template"]["TemplateData"];
        assert!(td.is_string(), "TemplateData 必须是字符串，实际是 {:?}", td);
        // 字符串内容本身还得是合法 JSON，且含 code
        let inner: serde_json::Value = serde_json::from_str(td.as_str().unwrap()).unwrap();
        assert_eq!(inner["code"], "654321");
    }

    /// `Destination`（收件人）必须是**数组**；`TemplateID` 必须是**数字**。
    #[test]
    fn test_destination_is_array_and_template_id_is_number() {
        let body: serde_json::Value = serde_json::from_str(
            &build_body(&cfg_with("100091"), "user@example.com", "000001").unwrap(),
        )
        .unwrap();

        assert!(body["Destination"].is_array(), "Destination 必须是数组");
        assert_eq!(body["Destination"][0], "user@example.com");
        assert!(
            body["Template"]["TemplateID"].is_u64(),
            "TemplateID 必须是数字（传字符串会被判参数类型错）"
        );
        assert_eq!(body["Template"]["TemplateID"], 100091);
        // 主题必填（腾讯云不认「模板里有摘要」这件事）
        assert_eq!(body["Subject"], SUBJECT);
        // 回复地址指向我们能收信的邮箱
        assert_eq!(body["ReplyToAddresses"], "support@keyievolution.fun");
    }

    /// 模板 ID 非数字 → 明确报错（而不是把字符串塞进 JSON 让腾讯云去挑错）。
    #[test]
    fn test_non_numeric_template_id_rejected() {
        let err = build_body(&cfg_with("abc"), "a@b.com", "123456").unwrap_err();
        assert!(
            err.contains("TENCENT_SES_TEMPLATE_ID"),
            "错误信息须点明是哪个变量：{err}"
        );
    }

    /// 配置解析：缺任一项 → `None`（视作未配置），而不是「部分配置」。
    #[test]
    fn test_config_requires_all_fields() {
        // 全齐 → Some
        let full = |k: &str| match k {
            "TENCENT_SES_SECRET_ID" => Some("id".to_string()),
            "TENCENT_SES_SECRET_KEY" => Some("key".to_string()),
            "TENCENT_SES_FROM" => Some("f@x.com".to_string()),
            "TENCENT_SES_TEMPLATE_ID" => Some("1".to_string()),
            _ => None,
        };
        assert!(SesConfig::from_lookup(full).is_some());

        // 缺 TEMPLATE_ID → None
        let missing = |k: &str| match k {
            "TENCENT_SES_SECRET_ID" => Some("id".to_string()),
            "TENCENT_SES_SECRET_KEY" => Some("key".to_string()),
            "TENCENT_SES_FROM" => Some("f@x.com".to_string()),
            _ => None,
        };
        assert!(
            SesConfig::from_lookup(missing).is_none(),
            "缺模板 ID 必须视作未配置"
        );

        // 空串也算未配置（避免「变量存在但为空」被当成配好了）
        let empty = |k: &str| match k {
            "TENCENT_SES_SECRET_ID" => Some(String::new()),
            "TENCENT_SES_SECRET_KEY" => Some("key".to_string()),
            "TENCENT_SES_FROM" => Some("f@x.com".to_string()),
            "TENCENT_SES_TEMPLATE_ID" => Some("1".to_string()),
            _ => None,
        };
        assert!(
            SesConfig::from_lookup(empty).is_none(),
            "空密钥必须视作未配置"
        );
    }

    /// 未配置时 `send_verification_code` 必须**明确失败**（不能被当成发信成功）。
    #[test]
    fn test_unconfigured_returns_error() {
        // 注意：只断言「配置缺失 → Err」这条纯逻辑分支，
        // 不去动真实环境变量（那会与并行测试打架）。
        let cfg = SesConfig::from_lookup(|_| None);
        assert!(cfg.is_none());
    }
}
