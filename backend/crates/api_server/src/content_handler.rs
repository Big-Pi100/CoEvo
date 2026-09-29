//! 信息流接口 —— `GET /api/feed` · `GET /api/feed/{id}`
//!
//! # 🔴 **不验证登录态**（产品原则，不是遗漏）
//!
//! > 「除生词表上限外**不验证登录态**」「登录态是**能力限制开关**，不是**内容可见性开关**」
//!
//! 读信息流 / 打开文章属**内容渲染** → **不得**被登录态阻塞。
//! 🔑 因此本文件**不引入** `auth_middleware` —— 将来若有人要加，请先回看这条原则：
//!    把「易失败的外部依赖」（登录/网络）放到「内容渲染」的前置条件上，
//!    代价是**整个信息流打不开**，而收益只是「能统计谁看了」。
//!    （同族判据：「登录态不该成为内容渲染的前置条件」。）
//!
//! # 分层
//! 本层只做「查库 + 组 JSON」。**分类/排序的判据都写在这里**（一处定义），
//! 不散到 SQL 字符串外的地方。

use axum::extract::{Path, Query};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;

/// 单页最多返回多少条（**上限是防滥用**，不是产品需求）。
const MAX_LIMIT: i64 = 50;
const DEFAULT_LIMIT: i64 = 20;

/// 允许的排序（**白名单**，防止把排序字段变成注入面）。
///
/// 🔑 判据同 `review_list_query` 的 `allowedOrders`：**不接受调用方传任意 SQL**。
const SORT_BY_TIME: &str = "time";
const SORT_BY_SCORE: &str = "score";

#[derive(Debug, Deserialize)]
pub struct FeedQuery {
    pub category: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// `time`（默认）| `score`（热帖）
    pub sort: Option<String>,
}

/// 把 query 归一成安全的 (limit, offset, order_sql)。
///
/// 抽成独立函数是为了**可断言**：边界（负数 / 超大 / 非法排序值）都在这里收口，
/// 而不是散在 handler 里各判一次。
fn normalize(q: &FeedQuery) -> (i64, i64, &'static str) {
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let offset = q.offset.unwrap_or(0).max(0);
    let order = match q.sort.as_deref() {
        Some(SORT_BY_SCORE) => "p.score DESC, COALESCE(p.published_at, p.fetched_at) DESC",
        // 兜底走时间（含 `sort` 传了非法值的情况 —— 白名单未命中即回退）
        _ => "COALESCE(p.published_at, p.fetched_at) DESC",
    };
    (limit, offset, order)
}

/// `GET /api/feed?category=&limit=&offset=&sort=`
///
/// 🔑 列表**不返回 `body`**（全文可能几 KB，一页 20 条就是几十 KB）。
///    用 `has_body` 告诉端侧「这一条有没有全文可看」，端侧按需再去 `/api/feed/{id}` 取。
pub async fn feed_list_handler(Query(q): Query<FeedQuery>) -> Response {
    let (limit, offset, order) = normalize(&q);
    let conn = crate::db_pool::get_conn();

    // 分类筛选：`None` / 空串 → 不筛（用 `?1 IS NULL` 统一处理，避免拼 SQL）
    let category: Option<&str> = q.category.as_deref().filter(|c| !c.trim().is_empty());

    let sql = format!(
        "SELECT p.id, p.title, p.summary, p.url, p.author, p.category, \
                p.published_at, p.score, p.comments, \
                CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END AS has_body, \
                s.name AS source_name \
         FROM content_pool p \
         LEFT JOIN content_source s ON s.id = p.source_id \
         WHERE (?1 IS NULL OR p.category = ?1) \
         ORDER BY {} LIMIT ?2 OFFSET ?3",
        order // 已白名单化，非用户输入
    );

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("feed_list prepare 失败: {}", e);
            return err(StatusCode::INTERNAL_SERVER_ERROR, "db_error");
        }
    };

    let rows = stmt.query_map(rusqlite::params![category, limit, offset], |r| {
        Ok(serde_json::json!({
            "id":          r.get::<_, i64>(0)?,
            "title":       r.get::<_, String>(1)?,
            "summary":     r.get::<_, Option<String>>(2)?,
            "url":         r.get::<_, String>(3)?,
            "author":      r.get::<_, Option<String>>(4)?,
            "category":    r.get::<_, Option<String>>(5)?,
            "published_at": r.get::<_, Option<String>>(6)?,
            "score":       r.get::<_, Option<i64>>(7)?,
            "comments":    r.get::<_, Option<i64>>(8)?,
            "has_body":    r.get::<_, i64>(9)? == 1,
            "source":      r.get::<_, Option<String>>(10)?,
        }))
    });

    let items: Vec<serde_json::Value> = match rows {
        Ok(it) => it.filter_map(|x| x.ok()).collect(),
        Err(e) => {
            tracing::error!("feed_list query 失败: {}", e);
            return err(StatusCode::INTERNAL_SERVER_ERROR, "db_error");
        }
    };

    let total: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM content_pool WHERE (?1 IS NULL OR category = ?1)",
            rusqlite::params![category],
            |r| r.get(0),
        )
        .unwrap_or(0);

    (
        StatusCode::OK,
        Json(serde_json::json!({"ok": true, "items": items, "total": total, "limit": limit, "offset": offset})),
    )
        .into_response()
}

/// `GET /api/feed/{id}` —— 单篇（**含 `body` 全文**）。
pub async fn feed_detail_handler(Path(id): Path<i64>) -> Response {
    let conn = crate::db_pool::get_conn();

    let row = conn.query_row(
        "SELECT p.id, p.title, p.summary, p.body, p.url, p.author, p.category, \
                p.published_at, p.fetched_at, p.word_count, p.score, p.comments, \
                s.name AS source_name, s.license \
         FROM content_pool p \
         LEFT JOIN content_source s ON s.id = p.source_id \
         WHERE p.id = ?1",
        rusqlite::params![id],
        |r| {
            Ok(serde_json::json!({
                "id":           r.get::<_, i64>(0)?,
                "title":        r.get::<_, String>(1)?,
                "summary":      r.get::<_, Option<String>>(2)?,
                "body":         r.get::<_, Option<String>>(3)?,
                "url":          r.get::<_, String>(4)?,
                "author":       r.get::<_, Option<String>>(5)?,
                "category":     r.get::<_, Option<String>>(6)?,
                "published_at": r.get::<_, Option<String>>(7)?,
                "fetched_at":   r.get::<_, Option<String>>(8)?,
                "word_count":   r.get::<_, Option<i64>>(9)?,
                "score":        r.get::<_, Option<i64>>(10)?,
                "comments":     r.get::<_, Option<i64>>(11)?,
                "source":       r.get::<_, Option<String>>(12)?,
                "license":      r.get::<_, Option<String>>(13)?,
            }))
        },
    );

    match row {
        Ok(v) => (StatusCode::OK, Json(serde_json::json!({"ok": true, "item": v}))).into_response(),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            err(StatusCode::NOT_FOUND, "not_found")
        }
        Err(e) => {
            tracing::error!("feed_detail 失败 id={}: {}", id, e);
            err(StatusCode::INTERNAL_SERVER_ERROR, "db_error")
        }
    }
}

fn err(code: StatusCode, msg: &str) -> Response {
    (code, Json(serde_json::json!({"ok": false, "error": msg}))).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_clamps_limit() {
        let q = |l: Option<i64>| FeedQuery { category: None, limit: l, offset: None, sort: None };
        assert_eq!(normalize(&q(None)).0, DEFAULT_LIMIT);
        assert_eq!(normalize(&q(Some(0))).0, 1, "0 → 抬到 1");
        assert_eq!(normalize(&q(Some(-5))).0, 1, "负数 → 抬到 1");
        assert_eq!(normalize(&q(Some(999))).0, MAX_LIMIT, "超大 → 压到上限");
        assert_eq!(normalize(&q(Some(10))).0, 10);
    }

    #[test]
    fn test_normalize_offset_non_negative() {
        let q = FeedQuery { category: None, limit: None, offset: Some(-3), sort: None };
        assert_eq!(normalize(&q).1, 0);
    }

    #[test]
    fn test_normalize_sort_whitelist() {
        let mk = |s: Option<&str>| FeedQuery {
            category: None,
            limit: None,
            offset: None,
            sort: s.map(|x| x.to_string()),
        };
        assert!(normalize(&mk(Some("score"))).2.contains("score DESC"));
        assert!(normalize(&mk(Some("time"))).2.contains("published_at"));
        // 🔴 非法值 → 回退到时间，而不是拼进 SQL（注入面）
        let injected = normalize(&mk(Some("id; DROP TABLE content_pool"))).2;
        assert!(injected.contains("published_at"), "非法排序应回退: {}", injected);
        assert!(!injected.contains("DROP"), "不得把用户输入拼进 SQL: {}", injected);
    }
}
