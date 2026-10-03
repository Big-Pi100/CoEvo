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

// 🔴 2026-10-03：这里原有 `SORT_BY_TIME` / `SORT_BY_SCORE` 两个白名单常量
//    （对应 `?sort=time|score`，其中 `score` 是「热帖」排序）。
//
//    白哥决定放弃 HN ⇒ `content_pool.score` 列已删 ⇒ **「热帖排序」不复存在**，
//    两个常量随之移除。顺带说明：`SORT_BY_TIME` 此前**只有定义、从未被消费**
//    —— 也就是说它是**死代码**，正好一并清掉。

#[derive(Debug, Deserialize)]
pub struct FeedQuery {
    pub category: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    // 🔴 原 `sort: Option<String>`（`time` | `score`）已移除 —— 见上方说明。
    //    ⚠️ 兼容性：`FeedQuery` **没有** `deny_unknown_fields`，
    //       所以老客户端仍传 `?sort=xxx` 也**不会报错**，只是被忽略（仍是时间序）。
    /// 🔑 **按 id 批量取**（逗号分隔）—— 供「收藏清单」用。
    ///
    /// # 为什么需要它（而不是让端侧逐条调 `/api/feed/{id}`）
    /// 收藏清单只知道一串 `content_id`（来自端侧 `bookmark` 表），需要反查卡片内容。
    /// 逐条调 = N 次请求 → N 次握手 + N 次 DB 往返（收藏 50 条就是 50 次）。
    /// 而「按 id 批量」是一次查询解决 —— 且**复用同一个 handler**，不新增接口面。
    ///
    /// ⚠️ 与 `category` / `limit` 的关系：给了 `ids` 时**忽略分页与排序**
    ///    （用户要的就是「这几个 id」，多给或漏给都是错的）。
    pub ids: Option<String>,
}

/// 解析 `ids=1,2,3` → `Vec<i64>`。
///
/// # 🔴 解析成整数再用参数绑定（**不是**把字符串拼进 SQL）
/// `ids` 是**用户输入**。若拼进 SQL 就是注入面。
/// 这里先解析成 `i64` 集合 —— 非法片段（非数字）**直接丢弃**，
/// 之后用**动态生成的占位符**（`?,?,?`）绑定参数。
/// 🔑 占位符的个数来自**解析后的整数个数**，与用户输入的原始字符串无关 → 无注入面。
///
/// 去重（同一个 id 传两次只查一次）+ 上限（防止 `ids=` 塞几千个）。
fn parse_ids(raw: &str) -> Vec<i64> {
    /// 一次最多按 id 取多少条 —— 与 `MAX_LIMIT` 同量级。
    const MAX_IDS: usize = 100;
    let mut out: Vec<i64> = Vec::new();
    for part in raw.split(',') {
        if let Ok(v) = part.trim().parse::<i64>() {
            if v > 0 && !out.contains(&v) {
                out.push(v);
                if out.len() >= MAX_IDS {
                    break;
                }
            }
        }
        // 非法片段静默丢弃：调用方拿到的条目数会少于请求数，
        // 由端侧按「响应里没有的 id 就是不存在的」处理（不是错误）
    }
    out
}

/// 把 query 归一成安全的 (limit, offset, order_sql)。
///
/// 抽成独立函数是为了**可断言**：边界（负数 / 超大 / 非法排序值）都在这里收口，
/// 而不是散在 handler 里各判一次。
fn normalize(q: &FeedQuery) -> (i64, i64, &'static str) {
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let offset = q.offset.unwrap_or(0).max(0);
    // 🔴 2026-10-03：原来这里按 `sort` 白名单选 `order`（`time` / `score`）。
    //    放弃 HN ⇒ `score` 列已删 ⇒ **只剩「按时间倒序」一种** ⇒ 白名单与 match 都移除。
    (limit, offset, "COALESCE(p.published_at, p.fetched_at) DESC")
}

/// `GET /api/feed?category=&limit=&offset=&sort=`
///
/// 🔑 列表**不返回 `body`**（全文可能几 KB，一页 20 条就是几十 KB）。
///    用 `has_body` 告诉端侧「这一条有没有全文可看」，端侧按需再去 `/api/feed/{id}` 取。
pub async fn feed_list_handler(Query(q): Query<FeedQuery>) -> Response {
    // 🔑 `ids` 优先：给了它就是要「这几个」，分页/排序无意义（见 `FeedQuery::ids`）
    if let Some(raw) = q.ids.as_deref() {
        return feed_by_ids(raw);
    }

    let (limit, offset, order) = normalize(&q);
    let conn = crate::db_pool::get_conn();

    // 分类筛选：`None` / 空串 → 不筛（用 `?1 IS NULL` 统一处理，避免拼 SQL）
    let category: Option<&str> = q.category.as_deref().filter(|c| !c.trim().is_empty());

    let sql = format!(
        "SELECT p.id, p.title, p.summary, p.url, p.author, p.category, \
                p.published_at, \
                CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END AS has_body, \
                s.name AS source_name, p.word_count \
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
            "has_body":    r.get::<_, i64>(7)? == 1,
            "source":      r.get::<_, Option<String>>(8)?,
            // 🔑 `word_count` 是**事实**（让端侧自己算「N min」这个展示口径）——
            //    与 `Article.lookups` 存 `reps` 不存样式同一条原则：
            //    「数据层存事实，渲染层算表现」。列表与详情都返回它。
            "word_count":  r.get::<_, Option<i64>>(9)?,
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

/// `GET /api/feed?ids=1,2,3` —— 按 id 批量取（收藏清单用）。
///
/// # 与列表接口的**形状一致**（`{ok, items, total, limit, offset}`）
/// 🔑 端侧因此只需**一套**解析代码。`limit`/`offset` 填实际值（`items.len()` / 0）。
///
/// # 🔴 返回顺序**不保证**等于请求顺序 —— 端侧要按自己的顺序重排
/// 调用方（收藏清单）的顺序是「收藏时间倒序」，那是**端侧 `bookmark` 表的顺序**。
/// 这里按 `published_at DESC` 返回（SQL 的 `IN` 本就不保证顺序）。
/// → 端侧用 `{for (final it in items) it.id: it}` 建映射再按自己的顺序取，
///   **不要**依赖响应顺序。
///
/// # 找不到的 id **静默跳过**（不是错误）
/// 收藏的内容可能已从内容池清理掉（保留期策略）→ 端侧按「响应里没有 = 不可渲染」处理。
/// 若这里报错，一条失效收藏会让**整个收藏清单打不开**。
fn feed_by_ids(raw: &str) -> Response {
    let ids = parse_ids(raw);
    if ids.is_empty() {
        // 非法/空 ids → 返回空列表而不是 400：调用方拿不到内容，与「这些 id 都不存在」同类
        return (
            StatusCode::OK,
            Json(serde_json::json!({"ok": true, "items": [], "total": 0, "limit": 0, "offset": 0})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();
    // 占位符个数来自**解析后的整数个数**（与用户输入的原始字符串无关）→ 无注入面
    let placeholders = vec!["?"; ids.len()].join(",");
    let sql = format!(
        "SELECT p.id, p.title, p.summary, p.url, p.author, p.category, \
                p.published_at, \
                CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END AS has_body, \
                s.name AS source_name, p.word_count \
         FROM content_pool p \
         LEFT JOIN content_source s ON s.id = p.source_id \
         WHERE p.id IN ({}) \
         ORDER BY COALESCE(p.published_at, p.fetched_at) DESC",
        placeholders
    );

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("feed_by_ids prepare 失败: {}", e);
            return err(StatusCode::INTERNAL_SERVER_ERROR, "db_error");
        }
    };

    let params: Vec<&dyn rusqlite::ToSql> = ids.iter().map(|i| i as &dyn rusqlite::ToSql).collect();
    let items: Vec<serde_json::Value> = match stmt.query_map(params.as_slice(), |r| {
        Ok(serde_json::json!({
            "id":          r.get::<_, i64>(0)?,
            "title":       r.get::<_, String>(1)?,
            "summary":     r.get::<_, Option<String>>(2)?,
            "url":         r.get::<_, String>(3)?,
            "author":      r.get::<_, Option<String>>(4)?,
            "category":    r.get::<_, Option<String>>(5)?,
            "published_at": r.get::<_, Option<String>>(6)?,
            "has_body":    r.get::<_, i64>(7)? == 1,
            "source":      r.get::<_, Option<String>>(8)?,
            // 🔑 `word_count` 是**事实**（让端侧自己算「N min」这个展示口径）——
            //    与 `Article.lookups` 存 `reps` 不存样式同一条原则：
            //    「数据层存事实，渲染层算表现」。列表与详情都返回它。
            "word_count":  r.get::<_, Option<i64>>(9)?,
        }))
    }) {
        Ok(it) => it.filter_map(|x| x.ok()).collect(),
        Err(e) => {
            tracing::error!("feed_by_ids query 失败: {}", e);
            return err(StatusCode::INTERNAL_SERVER_ERROR, "db_error");
        }
    };

    let total = items.len() as i64;
    (
        StatusCode::OK,
        Json(serde_json::json!({"ok": true, "items": items, "total": total, "limit": total, "offset": 0})),
    )
        .into_response()
}

/// `GET /api/feed/{id}` —— 单篇（**含 `body` 全文**）。
pub async fn feed_detail_handler(Path(id): Path<i64>) -> Response {
    let conn = crate::db_pool::get_conn();

    let row = conn.query_row(
        "SELECT p.id, p.title, p.summary, p.body, p.url, p.author, p.category, \
                p.published_at, p.fetched_at, p.word_count, \
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
                "source":       r.get::<_, Option<String>>(10)?,
                "license":      r.get::<_, Option<String>>(11)?,
            }))
        },
    );

    match row {
        Ok(v) => (
            StatusCode::OK,
            Json(serde_json::json!({"ok": true, "item": v})),
        )
            .into_response(),
        Err(rusqlite::Error::QueryReturnedNoRows) => err(StatusCode::NOT_FOUND, "not_found"),
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
        let q = |l: Option<i64>| FeedQuery {
            category: None,
            limit: l,
            offset: None,
            ids: None,
        };
        assert_eq!(normalize(&q(None)).0, DEFAULT_LIMIT);
        assert_eq!(normalize(&q(Some(0))).0, 1, "0 → 抬到 1");
        assert_eq!(normalize(&q(Some(-5))).0, 1, "负数 → 抬到 1");
        assert_eq!(normalize(&q(Some(999))).0, MAX_LIMIT, "超大 → 压到上限");
        assert_eq!(normalize(&q(Some(10))).0, 10);
    }

    #[test]
    fn test_normalize_offset_non_negative() {
        let q = FeedQuery {
            category: None,
            limit: None,
            offset: Some(-3),
            ids: None,
        };
        assert_eq!(normalize(&q).1, 0);
    }

    /// 🔴 2026-10-03 改写：原为 `test_normalize_sort_whitelist`，测「`sort` 值白名单」。
    ///
    /// 放弃 HN ⇒ `sort` 参数与 `score` 列都移除 ⇒ **白名单本身不存在了**。
    /// 但它守的**核心关切仍然成立**：`order` 必须是**编译期常量**，
    /// 绝不能让调用方输入以任何形式拼进 SQL（那才是注入面）。
    /// ⇒ 改成直接锁「`order` 恒等于那条固定 SQL」—— 比原来更强
    ///    （原测试只验「非法值不出现 DROP」，现在验「任何输入下 order 都不变」）。
    #[test]
    fn test_normalize_order_is_constant() {
        // 造一个「字段全填」的 query —— 现在 `sort` 已不存在，
        // 老客户端若仍传 `?sort=xxx` 会被 serde **忽略**（未 deny_unknown_fields）。
        let q = FeedQuery {
            category: Some("news".into()),
            limit: Some(5),
            offset: Some(0),
            ids: None,
        };
        assert_eq!(
            normalize(&q).2,
            "COALESCE(p.published_at, p.fetched_at) DESC",
            "order 必须是固定常量 —— 绝不能包含任何调用方输入"
        );
    }

    #[test]
    fn test_parse_ids_happy_path() {
        assert_eq!(parse_ids("1,2,3"), vec![1, 2, 3]);
        assert_eq!(parse_ids(" 7 , 8 "), vec![7, 8], "容忍空白");
    }

    #[test]
    fn test_parse_ids_drops_garbage() {
        // 🔴 非法片段**丢弃**而不是报错：一条坏 id 不该让整个收藏清单打不开
        assert_eq!(parse_ids("1,abc,2"), vec![1, 2]);
        assert_eq!(parse_ids(""), Vec::<i64>::new());
        assert_eq!(parse_ids("abc"), Vec::<i64>::new());
        // 负数与 0 不是合法 id（AUTOINCREMENT 从 1 开始）
        assert_eq!(parse_ids("0,-1,5"), vec![5]);

        // ⚠️ **只有逗号是分隔符** —— `1;;2` 是**一个**（非法的）片段 → 整体丢弃，
        //    不是 `[1,2]`。我第一版把这个期望写错了（以为分号也分隔）。
        // 🔑 这个行为是对的：`parse::<i64>()` 要求整段都是数字，
        //    任何夹带（分号/空格/字母）都会被拒 → **宁可少取，不猜**。
        assert_eq!(parse_ids("1;;2"), Vec::<i64>::new());
    }

    #[test]
    fn test_parse_ids_dedup_and_cap() {
        // 去重：同一个 id 传两次只查一次
        assert_eq!(parse_ids("5,5,5"), vec![5]);
        // 上限：防止 `ids=` 塞几千个
        let many: String = (1..=500)
            .map(|i| i.to_string())
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(parse_ids(&many).len(), 100, "应压到 MAX_IDS");
        // 🔴 上限截断后仍是**前 100 个**（不是随机/倒序）
        assert_eq!(parse_ids(&many)[0], 1);
        assert_eq!(parse_ids(&many)[99], 100);
    }

    #[test]
    fn test_parse_ids_sql_injection_attempt_is_just_a_non_number() {
        // 注入尝试 → 整段不是合法整数 → 丢弃（占位符个数只由解析后的整数决定）
        assert_eq!(parse_ids("1; DROP TABLE content_pool--"), Vec::<i64>::new());
        // 而**逗号分隔**时，只有干净的那个整数会留下
        assert_eq!(parse_ids("1,2;DROP TABLE content_pool--"), vec![1]);
    }
}
