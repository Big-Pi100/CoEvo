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

/// 解析 `category=tech,science` → **规范化后的逗号串**（形如 `",science,tech,"`）。
///
/// # 🔴 与 `parse_ids` 的关键差别：本函数**不参与拼 SQL**
///
/// `ids` 走的是「动态占位符 `?,?,?`」；这里走 **`INSTR` 单参数**方案：
///
/// ```sql
/// WHERE (?1 IS NULL OR INSTR(?1, ',' || p.category || ',') > 0)
/// ```
///
/// **为什么不用 `IN (?,?,?)`**（那样与 `parse_ids` 更对称）：
/// 单参数方案下 **SQL 结构完全不变** ⇒ 参数**个数与顺序**都不变
/// ⇒ 改动面最小，且不必靠断言去守「动态占位符个数 == 参数个数」这种一致性。
/// 代价：`INSTR` 用不上索引（当前 990 行，毫秒级）。
/// ⚠️ **将来规模上来要换 `IN` + 动态占位符，并把 `category` 索引一起加上** ——
///    届时不换只是变慢（不是错），所以现在选「不易出错」这一边。
/// 📌 判据：**改动面小的方案要显式写下它的代价与触发条件**，否则「临时方案」会永久留下。
///
/// # 🔑 为什么是 `,x,y,` 形态（前后都带逗号）
/// 直接 `INSTR('tech,science', category)` 会**误匹配**：`tech` 命中 `technology`。
/// 逗号包裹后才是**精确的集合成员判定**。
///
/// # ✅ 白名单过滤是安全边界的**唯一**来源
/// `category` 是**用户输入**。这里**只保留** [`crate::schema::CONTENT_CATEGORIES`]
/// 里存在的值 ⇒ 拼进参数的值**只能来自代码常量**，与用户输入无关（无注入面）。
/// 非法片段**静默丢弃**（与 `parse_ids` 同一约定）+ 去重 + 天然上限（白名单仅 12 个）。
///
/// 🔴 **「空集」与「没传」必须区分**（本函数最容易写错的一处）：
///
/// | 输入 | 返回 | 行为 |
/// |---|---|---|
/// | `None` / `""` / 纯空白 | `None` | **不筛**（返回全部）|
/// | `"tech"` | `Some(",tech,")` | 只返回该分类 |
/// | `"tech,xyz"` | `Some(",tech,")` | 非法值丢弃 ⇒ 等价于只传 `tech` |
/// | `"xyz"`（**全非法**）| `Some(",")` | **返回空**（`INSTR` 永不匹配）|
///
/// ⚠️ 最后一行是重点：**旧行为**是 `p.category = 'xyz'` ⇒ 空结果。
///    若把「全非法」也当成 `None`，就从「返回空」变成「**返回全部**」——
///    那是**静默的行为反转**（用户明明传了筛选条件，却拿到未筛选的结果）。
///    ⇒ 断言 `test_parse_categories` 专门锁这一条。
///
/// 排序：规范化后**按字典序排**，让「相同集合 ⇒ 相同字符串」
/// （便于日志聚合与人工比对；对 `INSTR` 本身无影响）。
fn parse_categories(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None; // 没传 ⇒ 不筛（**不是**「筛出空」）
    }
    let mut seen: Vec<String> = Vec::new();
    for part in trimmed.split(',') {
        let k = part.trim().to_ascii_lowercase();
        // 白名单过滤 —— 这是安全边界
        if crate::schema::CONTENT_CATEGORIES.contains(&k.as_str()) && !seen.contains(&k) {
            seen.push(k);
        }
    }
    // ⚠️ 全非法 ⇒ `Some(",")`（**空集**，INSTR 永不匹配）—— 见上面表格最后一行
    seen.sort();
    // 🔑 空集必须**单独处理**：`format!(",{},", "")` 会得到 `",,"`（两个逗号）。
    //    虽然对 `INSTR` 而言 `",,"` 与 `","` **行为等价**（都永不匹配任何分类），
    //    但「空集」应当有**唯一且干净**的表示 —— 否则日志/断言里出现 `",,"`
    //    会让人以为「这里有两个空分类」；将来若有人把这个串 `split(',')` 解析回来，
    //    两者得到的元素个数也不同。
    //    📌 判据：**「行为等价」≠「表示可以随便」** —— 表示唯一是避免后续误判的前提。
    //    （本条由单测 `test_parse_categories_distinguishes_absent_from_all_invalid` 抓到。）
    if seen.is_empty() {
        Some(",".to_string())
    } else {
        Some(format!(",{},", seen.join(",")))
    }
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

    // 分类筛选（🆕 2026-10-03 支持**多值**：`?category=tech,science`）。
    //   `None` / 空串 → **不筛**；给了值 → 只返回这些分类。
    //   🔴 「没传」与「传了但全部非法」是**两种不同**的结果（不筛 vs 空结果），
    //      这个区分在 `parse_categories` 里 —— 见它的文档表格。
    let cat_filter: Option<String> = q.category.as_deref().and_then(parse_categories);

    let sql = format!(
        "SELECT p.id, p.title, p.summary, p.url, p.author, p.category, \
                p.published_at, \
                CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END AS has_body, \
                s.name AS source_name, p.word_count \
         FROM content_pool p \
         LEFT JOIN content_source s ON s.id = p.source_id \
         WHERE (?1 IS NULL OR INSTR(?1, ',' || p.category || ',') > 0) \
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

    let rows = stmt.query_map(rusqlite::params![cat_filter, limit, offset], |r| {
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
            // 🔴 `total` 的筛选条件必须与上面 `items` 的**逐字相同**（同一个 `cat_filter`）。
            //    两处不一致时**不报错**，只是 `total` 与 `items` 对不上 ⇒
            //    端侧 `hasMore`（`fetched < total`）**永远为真** ⇒ 无限上拉、每次都白请求。
            //    📌 判据：**「同一个口径」在多个 SQL 里出现时，必须由同一个值驱动**。
            "SELECT COUNT(*) FROM content_pool \
             WHERE (?1 IS NULL OR INSTR(?1, ',' || category || ',') > 0)",
            rusqlite::params![cat_filter],
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

    // ══════════════════════════════════════════════════════════════════
    // `parse_categories`（2026-10-03 · 兴趣筛选「多值」支持）
    // ══════════════════════════════════════════════════════════════════

    /// 🔴 **最重要的一条**：区分「没传」与「传了但全非法」。
    ///
    /// 两者都得到「空集合」的**直觉**，但行为必须相反：
    /// · 没传 → `None` → **不筛**（返回全部）
    /// · 全非法 → `Some(",")` → **空结果**
    ///
    /// 若把后者也归成 `None`，就变成「用户传了筛选条件，却拿到未筛选的全部」
    /// —— **静默的行为反转**，而且没有任何一处会报错。
    #[test]
    fn test_parse_categories_distinguishes_absent_from_all_invalid() {
        // ① 「没传」的三种形态 → 都不筛
        assert_eq!(parse_categories(""), None);
        assert_eq!(parse_categories("   "), None);
        assert_eq!(parse_categories("\t\n"), None);

        // ② 全非法 → **空集**（不是 None！）
        let all_invalid = parse_categories("xyz");
        assert_eq!(
            all_invalid.as_deref(),
            Some(","),
            "🔴 全非法必须是 Some(\",\")（空集 ⇒ INSTR 永不匹配 ⇒ 空结果），\
             不能是 None（那会变成「不筛」⇒ 返回全部）"
        );
        // 语义确认：空集串**不含**任何合法 key
        assert!(!all_invalid.unwrap().contains("tech"));
    }

    #[test]
    fn test_parse_categories_basic_and_multi() {
        // 单值：行为与旧的 `p.category = ?1` **等价**
        assert_eq!(parse_categories("tech").as_deref(), Some(",tech,"));
        // 🔑 逗号包裹是精确成员判定 ⇒ `tech` **不会**误匹配 `technology`
        let one = parse_categories("tech").unwrap();
        assert!(
            !one.contains(",technology,"),
            "逗号包裹后不该匹配 technology"
        );

        // 多值
        assert_eq!(
            parse_categories("tech,science").as_deref(),
            Some(",science,tech,"),
            "规范化后按字典序排（相同集合 ⇒ 相同串）"
        );
        // 顺序无关：输入顺序不同 ⇒ **同一串**
        assert_eq!(
            parse_categories("tech,science"),
            parse_categories("science,tech")
        );
        // 空白容忍
        assert_eq!(
            parse_categories(" tech , science ").as_deref(),
            Some(",science,tech,")
        );
        // 大小写归一
        assert_eq!(parse_categories("TECH").as_deref(), Some(",tech,"));
    }

    #[test]
    fn test_parse_categories_drops_invalid_and_dedupes() {
        // 非法值**静默丢弃**（与 `parse_ids` 同约定）
        assert_eq!(parse_categories("tech,xyz").as_deref(), Some(",tech,"));
        // 去重
        assert_eq!(
            parse_categories("tech,tech,TECH").as_deref(),
            Some(",tech,")
        );
        // 全部合法值（12 个）都能通过白名单
        let all = crate::schema::CONTENT_CATEGORIES.join(",");
        let got = parse_categories(&all).unwrap();
        for k in crate::schema::CONTENT_CATEGORIES {
            assert!(got.contains(&format!(",{}", k)), "合法分类 {} 不该被丢", k);
        }
    }

    /// 🔴 安全边界：**拼进 SQL 参数的值只能来自代码白名单**。
    ///
    /// `parse_categories` 的输出会被当**绑定参数**用（不是拼 SQL），
    /// 所以本测试的意义是「**输出里不可能出现白名单以外的字符串**」——
    /// 即使输入是注入尝试。
    #[test]
    fn test_parse_categories_output_only_contains_whitelist() {
        let evil = parse_categories("'; DROP TABLE content_pool;--").unwrap();
        assert_eq!(evil, ",", "注入尝试 → 一个合法分类都没有 ⇒ 空集");
        assert!(!evil.contains("DROP"));

        // 混在合法值里的注入片段也被丢掉
        let mixed = parse_categories("tech,'; DROP TABLE content_pool;--").unwrap();
        assert_eq!(mixed, ",tech,");

        // 通配符也是非法值（我们**不**支持 `*`；「不筛」用「不传参数」表达）
        assert_eq!(parse_categories("*").as_deref(), Some(","));
    }
}
