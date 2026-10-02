//! Hacker News 适配器 —— 承载「**刷热帖**」形态（纯函数 · 零 IO）
//!
//! # 🔴 为什么是 HN 而不是 Reddit（白哥 2026-09-29 定）
//!
//! 白哥的原话：「**爱刷社交网络的比爱看新闻的多**」→ 产品上要「热帖」这种形态。
//! 但**Reddit 不能用来实现它**（事实，非偏好）：
//!
//! | 项 | Reddit | Hacker News |
//! |---|---|---|
//! | 商用许可 | 🔴 免费层**禁止商业应用**；商用 **~$12,000/年**起 + 人工审批 | ✅ **官方免费 API** |
//! | 法律风险 | 🔴 2025-10-22 **起诉搜索 API 供应商**（SerpApi/Oxylabs）—— 与 vibedollar 用的 AnySearch 同类模式 | ✅ 官方开放 |
//! | 内容质量 | 🔴 俚语/缩写（IMO/TL;DR/ELI5）· 语法随意（`u`/`ur`/`thx`）· NSFW 风险 | 🟡 英语规范、无 NSFW |
//!
//! 🔑 **「改个名字」不改变风险**（白哥曾提出「只说热帖不说信息源」）——
//!    风险取决于**数据怎么拿到**，不取决于界面叫什么。所以换的是**源**，不是措辞。
//!    HN 保留了「热帖榜 + 标题 + 分数 + 评论数」这套**形态**，需求被满足。
//!
//! # API 形态（与 RSS **完全不同**，所以是本模块而不是塞进 `content_rss`）
//!
//! ```text
//! GET /v0/topstories.json        → [id, id, ...]（500 个，按热度排序）
//! GET /v0/item/{id}.json         → {id, type, title, url, by, score, descendants, time, ...}
//! ```
//! 🔴 **没有批量接口** → N 条帖子要 N 次请求 → 必须有上限（见 [`DEFAULT_STORY_LIMIT`]）。
//!
//! ⚠️ `text` 标记**不能省**：`cargo test` 会把无语言标记的代码块当 **Rust doctest** 编译，
//!    于是这段 HTTP 说明会被当代码去跑 → doctest 失败（我踩过）。
//!
//! # 🔑 `url` 缺失是**常态**，不是异常
//! 「Ask HN」这类帖子**没有外链**（讨论就在 HN 站内）→ `url` 字段不存在。
//! 此时用**讨论页 URL** 兜底（`news.ycombinator.com/item?id={id}`）。
//! 🔴 这很重要：`url` 是入库的**幂等键**（`content_pool.UNIQUE(url)`）——
//!    若缺 url 就跳过，Ask HN 会**整类消失**；若留空串，多条会**互相覆盖**。

use serde_json::Value;

use crate::content_rss::{unix_to_utc_iso, ParsedItem};

/// 每次抓取最多取多少条热帖。
///
/// # 🔑 为什么是 60（而不是把 500 个 id 拉完）
/// HN **无批量接口** → 500 个 id = 500 次 HTTP 请求。
/// 每次抓取都这么干，对 HN 和我们自己都不合适（HN 是公益性质的官方 API）。
/// 60 条 ≈ 信息流 6 屏，而抓取每 6 小时一轮 → 足够覆盖。
///
/// ⚠️ 若要调大，请同时考虑：请求数 = 本值 × 源数 × 每轮次数。
pub const DEFAULT_STORY_LIMIT: usize = 60;

/// HN 讨论页 URL（`url` 缺失时的兜底 —— 见模块头）。
fn discussion_url(id: i64) -> String {
    format!("https://news.ycombinator.com/item?id={}", id)
}

/// 解析 `topstories.json` → **截断后的 id 列表**。
///
/// 截断放在这里（而非抓取器）是有意的：**「取多少条」是源适配的知识**，
/// 抓取器不该知道「HN 的列表有 500 个而我们不能全拉」。
pub fn parse_topstory_ids(json: &str, limit: usize) -> Result<Vec<i64>, String> {
    let v: Value =
        serde_json::from_str(json).map_err(|e| format!("topstories JSON 解析失败: {}", e))?;
    let arr = v
        .as_array()
        .ok_or_else(|| "topstories 不是数组（HN API 变了？）".to_string())?;

    let ids: Vec<i64> = arr.iter().filter_map(|x| x.as_i64()).collect();
    if ids.is_empty() {
        // 🔴 空数组要**报错**而不是返回空 —— 空列表会被上层当成「这轮没新内容」，
        //    从而把「API 挂了/改了」伪装成「正常无事发生」。
        return Err("topstories 数组为空或元素都不是整数".into());
    }
    Ok(ids.into_iter().take(limit).collect())
}

/// 解析单个 `item/{id}.json` → 可入库的条目。
///
/// 返回 `Ok(None)` 的情形（**都是正常跳过，不是错误**）：
/// · `type != "story"`（comment / job / poll 的形态与信息流不符）
/// · 无 `title`（没法展示）
/// · 无 `id`
///
/// 🔑 这就是「**开放 vs 封闭**」的处置差别：字段**缺失**是数据本身的性质（跳过），
///    而 JSON **语法错**才是错误（返回 `Err`）。两者不能混成一个 `None`。
pub fn parse_story_item(json: &str) -> Result<Option<ParsedItem>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("item JSON 解析失败: {}", e))?;

    // null 是 HN 的合法响应（id 不存在/已删除）→ 正常跳过
    if v.is_null() {
        return Ok(None);
    }
    if v.get("type").and_then(|t| t.as_str()) != Some("story") {
        return Ok(None);
    }
    let Some(id) = v.get("id").and_then(|x| x.as_i64()) else {
        return Ok(None);
    };
    let Some(title) = v
        .get("title")
        .and_then(|t| t.as_str())
        .filter(|t| !t.trim().is_empty())
    else {
        return Ok(None);
    };

    // url 优先（必须是 http 开头）；缺失 → 讨论页（见模块头）
    let url = v
        .get("url")
        .and_then(|u| u.as_str())
        .map(|s| s.trim())
        .filter(|s| s.starts_with("http"))
        .map(|s| s.to_string())
        .unwrap_or_else(|| discussion_url(id));

    // `text` 是 HTML（Ask HN 有）→ 剥成纯文本当正文；story 通常没有
    // 🔑 **正文用「保留段落」版本**（同 RSS 的 `classify_encoded`）—— 否则贴多段的
    //    Ask HN 会挤成一整行（HN 的 `<p>` 用得很多）
    let body = v
        .get("text")
        .and_then(|t| t.as_str())
        .map(crate::content_rss::strip_html_block)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    Ok(Some(ParsedItem {
        title: crate::content_rss::strip_html(title),
        // HN 没有「摘要」这个概念 → 不编造（body 有值就用 body，渲染层自己截）
        summary: None,
        body,
        url,
        author: v.get("by").and_then(|b| b.as_str()).map(|s| s.to_string()),
        published_at: v
            .get("time")
            .and_then(|t| t.as_i64())
            .and_then(unix_to_utc_iso),
        score: v.get("score").and_then(|s| s.as_i64()),
        comments: v.get("descendants").and_then(|d| d.as_i64()),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实样本（2026-09-29 抓自 HN 官方 API）
    const TOPSTORIES: &str = include_str!("../tests/fixtures/hn_topstories.json");
    const STORY_ITEM: &str = include_str!("../tests/fixtures/hn_item_story.json");

    #[test]
    fn test_parse_topstory_ids_and_truncate() {
        let ids = parse_topstory_ids(TOPSTORIES, 10).unwrap();
        assert_eq!(ids.len(), 10);
        // 真实样本第 1 个
        assert_eq!(ids[0], 49893876);

        // limit 生效
        let ids3 = parse_topstory_ids(TOPSTORIES, 3).unwrap();
        assert_eq!(ids3.len(), 3);
    }

    #[test]
    fn test_topstories_empty_errors_not_silent() {
        // 🔴 空数组必须报错 —— 否则「API 变了」会被当成「这轮无新内容」
        assert!(parse_topstory_ids("[]", 10).is_err());
        assert!(parse_topstory_ids("{}", 10).is_err());
        assert!(parse_topstory_ids("不是 json", 10).is_err());
        assert!(parse_topstory_ids(r#"["a","b"]"#, 10).is_err());
    }

    #[test]
    fn test_parse_real_story_item() {
        let it = parse_story_item(STORY_ITEM)
            .unwrap()
            .expect("真实样本应可解析");
        assert_eq!(it.title, "Claude partial outage");
        assert_eq!(it.author.as_deref(), Some("sidcool"));
        assert_eq!(it.score, Some(142));
        assert_eq!(it.comments, Some(104));
        // unix time → UTC ISO8601 带 Z
        assert!(
            it.published_at.as_deref().unwrap().ends_with('Z'),
            "{:?}",
            it.published_at
        );
        // 🔑 期望值**独立核算**（python `datetime.fromtimestamp(1790691941, utc)`），
        //    不是照抄代码输出 —— 我第一版手算成 03:45:41Z，是**错的**
        assert_eq!(it.published_at.as_deref(), Some("2026-09-29T14:25:41Z"));
        // story 无 text → body 为空（不编造）
        assert_eq!(it.body, None);
        assert_eq!(it.summary, None, "HN 没有摘要概念，不该编造");
    }

    #[test]
    fn test_ask_hn_without_url_uses_discussion_url() {
        // 🔴 url 缺失是常态（Ask HN 没有外链）→ 用讨论页兜底，保证幂等键存在
        // ⚠️ `text` 里是**真标签**（HN 返回 HTML），不是 `&lt;p&gt;` 这种转义 ——
        //    我第一版写成了转义形式，期望值就跟着错了（转义会被当**文本**保留）
        let json = r#"{"id":123,"type":"story","title":"Ask HN: 怎么学英语？","by":"alice",
                       "score":5,"descendants":3,"time":1790691941,
                       "text":"我想找<p>材料</p>"}"#;
        let it = parse_story_item(json).unwrap().unwrap();
        assert_eq!(it.url, "https://news.ycombinator.com/item?id=123");
        assert_eq!(
            it.body.as_deref(),
            Some("我想找材料"),
            "text 要剥 HTML 标签"
        );
    }

    #[test]
    fn test_non_story_and_malformed_are_skipped() {
        // comment / job / poll 都跳过
        for t in ["comment", "job", "poll"] {
            let json = format!(r#"{{"id":1,"type":"{}","title":"x"}}"#, t);
            assert!(
                parse_story_item(&json).unwrap().is_none(),
                "type={} 应跳过",
                t
            );
        }
        // 无 title
        assert!(parse_story_item(r#"{"id":1,"type":"story"}"#)
            .unwrap()
            .is_none());
        // null（HN 对不存在的 id 返回 null）→ 跳过而非报错
        assert!(parse_story_item("null").unwrap().is_none());
        // 🔴 但**语法错**要报错（区分「字段缺失」与「数据坏了」）
        assert!(parse_story_item("{坏 json").is_err());
    }

    #[test]
    fn test_rss_items_have_no_score() {
        // 反向：RSS 适配器不填 score/comments → 保证「热帖字段只由 HN 提供」
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
            <item><title>t</title><link>https://a.test/1</link></item>
        </channel></rss>"#;
        let items = crate::content_rss::parse_rss(xml, 0).unwrap();
        assert_eq!(items[0].score, None);
        assert_eq!(items[0].comments, None);
    }
}
