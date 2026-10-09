//! 云端书架的文件端点 —— **上传 / 下载 / 删除**
//!
//! # 与同步通道的分工（设计稿 §3 定）
//!
//! | 数据 | 走哪 | 为什么 |
//! |---|---|---|
//! | **书单元数据**（书名/作者/指纹/大小）| `POST /api/sync/push` 的 `books` | 小、结构化、与其余同步同一套合并规则 |
//! | **文件本体** | **本模块**的三个端点 | 大、二进制、需要配额与流式 |
//!
//! # 🔴 鉴权：写要订阅，读/删只要登录
//!
//! 见 [`crate::sync_handlers::authorize_login_only`] 的说明。
//! 一句话：**限制入口可以，限制出口不行** —— 用户付费期间存进去的书，
//! 订阅到期后仍必须能取回、能删除。
//!
//! # 🔴 上传前要求 `sync_book` 行已存在（顺序约束）
//!
//! 配额靠 `SUM(sync_book.blob_size)` 算 ⇒ 没有那一行就没法记账。
//! ⇒ 上传前先查，查不到回 **400 + 可读文案**（「请先同步书单」），
//!   而**不是**静默插入一行半成品（那样 `title` 会是空串，
//!   列表里出现一本没有名字的书）。
//!
//! ⚠️ **已知的并发窗口**（如实标注）：两个并发上传可能**同时**通过配额检查
//!    ⇒ 合计轻微超出 2 GB。不是安全漏洞（用户只能超额自己的配额），
//!   且端侧上传是**串行队列**（一次一本）。若将来改成并发上传，此处要加锁。

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Multipart, Path, Query, State};
use axum::http::header;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use rusqlite::params;
use serde::Deserialize;

use crate::book_storage::{
    check_quota, is_valid_content_hash, is_valid_ext, BlobStore, LocalDiskStore,
    CLOUD_BOOK_QUOTA_BYTES, MAX_BOOK_BYTES,
};
use crate::error::AppError;

/// 路由状态：存储后端。
///
/// 🔑 用 `Arc<dyn BlobStore>` 而不是具体类型 —— 切 COS 时**只换构造这一行**。
#[derive(Clone)]
pub struct BlobState {
    pub store: std::sync::Arc<dyn BlobStore>,
}

impl BlobState {
    /// 生产构造：本地盘（见 `book_storage` 文件头的选型说明）。
    pub fn from_env() -> Self {
        Self {
            store: std::sync::Arc::new(LocalDiskStore::from_env()),
        }
    }
}

/// 注册三个端点。
///
/// ⚠️ `DefaultBodyLimit` **必须**放大：axum 默认 body 上限 **2 MB**，
///    而电子书常见 0.3–10 MB ⇒ 不改的话用户会遇到「传书失败」且
///    原因藏在 413 里（端侧很可能只显示「上传失败」）。
///    留 1 MB 余量给 multipart 的分隔符与字段头。
pub fn blob_routes(state: BlobState) -> Router {
    Router::new()
        .route("/api/books/blob", post(upload_blob_handler))
        // 🔴 同一路径的两个方法必须**链式**写在一次 `route` 里：
        //    axum 对同一 path 调用两次 `route()` 会 **panic**
        //    （"Overlapping method route"）—— 而这在 `cargo check` 里**看不出来**，
        //    只在真正构造 Router 时（= 服务启动 / 测试运行）才炸。
        .route(
            "/api/books/blob/{content_hash}",
            get(download_blob_handler).delete(delete_blob_handler),
        )
        .layer(DefaultBodyLimit::max(
            (MAX_BOOK_BYTES + 1024 * 1024) as usize,
        ))
        .with_state(state)
}

// ══════════════════════════════════════════════════════════════════════
// 记账（抽成独立函数 ⇒ 可 `cargo test`）
// ══════════════════════════════════════════════════════════════════════

/// 该用户**当前占用**的云端空间 = 所有**未删除**书的 `blob_size` 之和。
///
/// 🔑 为什么排除 `deleted = 1`：
///    端侧删书是「推 `deleted=1`」+「调 DELETE 端点」**两个动作**，
///    其中 DELETE 可能失败（网络、重试上限）⇒ 文件残留。
///    若残留仍计入配额，用户会遇到「删了书但空间不减」——
///    他无法通过任何操作解决，只能等我们清理。**排除它**让用户不受影响；
///    残留文件由后续的孤儿清理任务处理（已记为遗留项）。
pub fn current_usage(conn: &rusqlite::Connection, uid: &str) -> Result<i64, AppError> {
    conn.query_row(
        "SELECT COALESCE(SUM(blob_size), 0) FROM sync_book
          WHERE user_id = ?1 AND deleted = 0",
        params![uid],
        |r| r.get(0),
    )
    .map_err(|e| AppError::Internal(format!("统计云端用量: {e}")))
}

/// 上传成功后记账：写入 `blob_size` 并**推进 `received_at`**。
///
/// 🔑 为什么必须推进 `received_at`：它是 pull 的时间轴。
///    若不推进，**用户的其他设备永远不知道「云端已经有这本书了」**
///    ⇒ 换机时看到书架里那本书没有云标记，以为备份没成功。
pub fn set_blob_size(
    conn: &rusqlite::Connection,
    uid: &str,
    content_hash: &str,
    size: i64,
    received_at: &str,
) -> Result<usize, AppError> {
    conn.execute(
        "UPDATE sync_book SET blob_size = ?3, received_at = ?4
          WHERE user_id = ?1 AND content_hash = ?2",
        params![uid, content_hash, size, received_at],
    )
    .map_err(|e| AppError::Internal(format!("更新 blob_size: {e}")))
}

/// 🔴 **按用户批量归零**（订阅到期满 30 天的清理用它）—— 与 [`set_blob_size`]
///    是**同一条约束的两个形态**：写 `blob_size` 时**必须**同时推进 `received_at`。
///
/// # 为什么必须走这里，而不能在调用方直接写 UPDATE
///
/// `received_at` 是 **pull 的时间轴**（`sync_handlers::pull_changes` 的
/// `WHERE received_at > ?since`）。清理只 `SET blob_size = 0` 而不动它的话，
/// 后果是**静默的**：
/// - 用户在**另一台设备**上（或同一台重装后）永远不知道备份已被释放
///   ⇒ 书架仍显示「云端有」⇒ 点下载 **404**。
///
/// 该后果在本函数被写出来之前**真实发生过**（`maintenance::purge_expired_blobs`
/// 曾自写裸 UPDATE）—— 而它不报错、不掉断言，只有真机换设备才看得见。
///
/// ⇒ 📌 判据：**写 `blob_size` 的 SQL 只允许出现在本模块**
///    （`set_blob_size` 单条 / `zero_blob_sizes_for_user` 批量）。
///    别处一律调函数 —— 否则「归零要推进时间轴」这条约束会在两处重复，
///    改一处漏一处，且漏的那一处**不会红**。
///
/// ⚠️ 与 [`set_blob_size`] 的差别只有范围：那个按 `content_hash` 单条，
///    这个按 `user_id` 批量（一个用户可能有多本书）。
pub fn zero_blob_sizes_for_user(
    conn: &rusqlite::Connection,
    uid: &str,
    received_at: &str,
) -> Result<usize, AppError> {
    conn.execute(
        "UPDATE sync_book SET blob_size = 0, received_at = ?2
          WHERE user_id = ?1 AND blob_size > 0",
        params![uid, received_at],
    )
    .map_err(|e| AppError::Internal(format!("清零 blob_size: {e}")))
}

/// `sync_book` 里有这本书吗（且未被端侧删除）。
///
/// ⚠️ 被软删的书**不允许**上传：否则用户「删了书 → 云端文件又被传回来」。
fn book_row_exists(
    conn: &rusqlite::Connection,
    uid: &str,
    content_hash: &str,
) -> Result<bool, AppError> {
    let n: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sync_book
              WHERE user_id = ?1 AND content_hash = ?2 AND deleted = 0",
            params![uid, content_hash],
            |r| r.get(0),
        )
        .map_err(|e| AppError::Internal(format!("查书单: {e}")))?;
    Ok(n > 0)
}

/// 🔑 `pub(crate)`：`maintenance::purge_expired_blobs` 清理时也要生成
///    `received_at` —— 与上传 / 删除**同一个形态**（服务端时刻，`%Y-%m-%dT%H:%M:%S%.3fZ`）。
///    ⚠️ 格式必须与别处**逐字节一致**：`received_at > since` 是**字符串比较**，
///       一旦格式不同（比如少了毫秒）⇒ 时间轴错乱 ⇒ pull 漏数据。
pub(crate) fn now_ms() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

// ══════════════════════════════════════════════════════════════════════
// ① 上传
// ══════════════════════════════════════════════════════════════════════

/// 写操作的准入：登录 + 订阅（上传消耗服务端资源）。
fn authorize_blob_write(headers: &axum::http::HeaderMap) -> Result<String, AppError> {
    let (uid, _token) = crate::sync_handlers::authorize_login_only(headers)?;
    let conn = crate::db_pool::get_conn();
    if !crate::subscription::is_subscription_active(&conn, &uid) {
        return Err(AppError::Forbidden(
            "云端书架是订阅权益，订阅后可备份书籍".into(),
        ));
    }
    Ok(uid)
}

/// `POST /api/books/blob` —— multipart：`content_hash` + `ext` + `file`。
pub async fn upload_blob_handler(
    State(st): State<BlobState>,
    headers: axum::http::HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<serde_json::Value>, AppError> {
    let uid = authorize_blob_write(&headers)?;

    // ── 收集字段 ──
    // ⚠️ 不能边读边处理：multipart 的**字段顺序由客户端决定**，
    //    `file` 完全可能出现在 `content_hash` 之前。
    let mut content_hash: Option<String> = None;
    let mut ext: Option<String> = None;
    let mut data: Option<Vec<u8>> = None;

    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(format!("multipart 解析失败：{e}")))?
    {
        // 🔑 先取出名字的**所有权**（`field.name()` 借用 field，随后要 move 它）
        let name = field.name().unwrap_or_default().to_string();
        match name.as_str() {
            "content_hash" => {
                content_hash = Some(
                    field
                        .text()
                        .await
                        .map_err(|e| AppError::BadRequest(format!("读 content_hash：{e}")))?,
                );
            }
            "ext" => {
                ext = Some(
                    field
                        .text()
                        .await
                        .map_err(|e| AppError::BadRequest(format!("读 ext：{e}")))?,
                );
            }
            "file" => {
                // ── 🔴 分块读 + **边读边限** ──
                // 不用 `field.bytes()`：它会把整个 body 一次读进内存，
                // 若有人传 10 GB，VPS（约 460 MB 可用）会 OOM。
                // 分块累计，越界立刻中断（Body limit 是第二道网）。
                let mut buf: Vec<u8> = Vec::new();
                while let Some(chunk) = field
                    .chunk()
                    .await
                    .map_err(|e| AppError::BadRequest(format!("读文件块：{e}")))?
                {
                    if buf.len() as i64 + chunk.len() as i64 > MAX_BOOK_BYTES {
                        return Err(AppError::BadRequest(format!(
                            "这本书超过单本上限（{} MB）",
                            MAX_BOOK_BYTES / 1024 / 1024
                        )));
                    }
                    buf.extend_from_slice(&chunk);
                }
                data = Some(buf);
            }
            // 未知字段忽略（前向兼容：端侧将来加字段不该让上传失败）
            _ => {}
        }
    }

    let content_hash = content_hash.unwrap_or_default();
    let ext = ext.unwrap_or_default();
    let data = data.ok_or_else(|| AppError::BadRequest("缺少 file 字段".into()))?;

    if !is_valid_content_hash(&content_hash) {
        return Err(AppError::BadRequest("content_hash 格式非法".into()));
    }
    if !is_valid_ext(&ext) {
        return Err(AppError::BadRequest(format!("不支持的格式：{ext:?}")));
    }
    if data.is_empty() {
        return Err(AppError::BadRequest("文件是空的".into()));
    }

    let received_at = now_ms();
    let (used, is_new) = {
        let conn = crate::db_pool::get_conn();
        // 🔴 顺序约束：书单必须先到（见模块头）
        if !book_row_exists(&conn, &uid, &content_hash)? {
            return Err(AppError::BadRequest(
                "这本书还没在书单里，请先同步书单再上传".into(),
            ));
        }
        let used = current_usage(&conn, &uid)?;
        // 覆盖式上传：同一本书重传**不额外占额度** ⇒ 先减掉它自己已占的部分
        let existing: i64 = conn
            .query_row(
                "SELECT COALESCE(blob_size, 0) FROM sync_book
                  WHERE user_id = ?1 AND content_hash = ?2",
                params![&uid, &content_hash],
                |r| r.get(0),
            )
            .map_err(|e| AppError::Internal(format!("查已占用量: {e}")))?;
        let is_new = existing == 0;

        // 🔑 配额判断基于「**净增量**」而不是「原始用量 + 新文件」：
        //    否则一本书 5 MB 重传两次就会把 2 GB 的额度算成用了 10 MB。
        check_quota(used - existing, data.len() as i64, CLOUD_BOOK_QUOTA_BYTES)
            .map_err(AppError::BadRequest)?;
        (used, is_new)
    };

    // ── 落盘（I/O 在事务外，见模块头的并发说明）──
    st.store
        .put(&uid, &content_hash, &ext, &data)
        .map_err(AppError::Internal)?;

    // ── 记账 ──
    let size = data.len() as i64;
    {
        let conn = crate::db_pool::get_conn();
        let n = set_blob_size(&conn, &uid, &content_hash, size, &received_at)?;
        if n == 0 {
            // 理论上不可达（上面刚查过存在）。但**不能静默** ——
            // 它意味着「文件已落盘但没人记账」⇒ 配额虚低。
            return Err(AppError::Internal(format!(
                "记账失败（书单行消失？）：{content_hash}"
            )));
        }
    }

    tracing::info!(
        "book_blob upload: uid={} hash={} ext={} bytes={} usage_before={} new={}",
        uid,
        content_hash,
        ext,
        size,
        used,
        is_new
    );

    Ok(Json(serde_json::json!({
        "ok": true,
        "blob_size": size,
        "usage": used - (if is_new { 0 } else { 0 }) + size,
        "quota": CLOUD_BOOK_QUOTA_BYTES,
    })))
}

// ══════════════════════════════════════════════════════════════════════
// ② 下载
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug, Deserialize)]
pub struct DownloadQuery {
    /// 文件格式。⚠️ 必填 —— 对象键含扩展名（见 `book_storage`）。
    ///    端侧知道自己的书是什么格式（`book` 表里有）。
    pub ext: Option<String>,
}

/// `GET /api/books/blob/{content_hash}?ext=epub` —— **流式**下载。
///
/// 🔑 **只需登录**（不需订阅）—— 见模块头。
pub async fn download_blob_handler(
    State(st): State<BlobState>,
    headers: axum::http::HeaderMap,
    Path(content_hash): Path<String>,
    Query(q): Query<DownloadQuery>,
) -> Result<Response, AppError> {
    let (uid, _token) = crate::sync_handlers::authorize_login_only(&headers)?;

    if !is_valid_content_hash(&content_hash) {
        return Err(AppError::BadRequest("content_hash 格式非法".into()));
    }
    let ext = q.ext.unwrap_or_default();
    if !is_valid_ext(&ext) {
        return Err(AppError::BadRequest(
            "缺少或非法的 ext 参数（需 epub / txt）".into(),
        ));
    }

    let path = st
        .store
        .local_path(&uid, &content_hash, &ext)
        .map_err(AppError::Internal)?
        .ok_or_else(|| {
            // ⚠️ 404 的文案要**能区分**「没上传过」与「上传失败」——
            //    两者在用户侧都是「点击没反应」的候选原因。
            AppError::NotFound("这本书在云端没有文件".into())
        })?;

    let file = tokio::fs::File::open(&path)
        .await
        .map_err(|e| AppError::Internal(format!("打开文件失败：{e}")))?;
    let total = file
        .metadata()
        .await
        .map_err(|e| AppError::Internal(format!("读文件元数据：{e}")))?
        .len();

    // 🔑 手写流式（本项目**没有** `tokio-util` 依赖，拉不动 `ReaderStream`）。
    //    用 `futures_util::stream::try_unfold` 分块读 ⇒ 内存占用恒为 64 KB，
    //    与文件大小无关。⇒ 下载 30 MB 的书与下载 1 MB 的书占用相同。
    let stream = futures_util::stream::try_unfold(file, |mut f| async move {
        use tokio::io::AsyncReadExt;
        let mut buf = vec![0u8; 64 * 1024];
        match f.read(&mut buf).await {
            Ok(0) => Ok::<_, std::io::Error>(None),
            Ok(n) => {
                buf.truncate(n);
                Ok(Some((axum::body::Bytes::from(buf), f)))
            }
            Err(e) => Err(e),
        }
    });

    let ctype = match ext.as_str() {
        "epub" => "application/epub+zip",
        // ⚠️ txt 用 `octet-stream` 而不是 `text/plain`：
        //    后者会让浏览器**直接渲染**（若将来有 Web 端下载入口，会看到正文乱码页）
        _ => "application/octet-stream",
    };

    Response::builder()
        .header(header::CONTENT_TYPE, ctype)
        .header(header::CONTENT_LENGTH, total.to_string())
        .body(Body::from_stream(stream))
        .map_err(|e| AppError::Internal(format!("构造响应失败：{e}")))
}

// ══════════════════════════════════════════════════════════════════════
// ③ 删除
// ══════════════════════════════════════════════════════════════════════

/// `DELETE /api/books/blob/{content_hash}` —— 删云端文件（配额随之退还）。
///
/// 🔑 **只需登录** —— 过期用户也必须能删掉自己的东西（否则配额永久占用）。
pub async fn delete_blob_handler(
    State(st): State<BlobState>,
    headers: axum::http::HeaderMap,
    Path(content_hash): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let (uid, _token) = crate::sync_handlers::authorize_login_only(&headers)?;

    if !is_valid_content_hash(&content_hash) {
        return Err(AppError::BadRequest("content_hash 格式非法".into()));
    }

    let freed = st
        .store
        .delete(&uid, &content_hash)
        .map_err(AppError::Internal)?;

    let received_at = now_ms();
    {
        let conn = crate::db_pool::get_conn();
        // 🔑 记账归零要推进 `received_at` —— 其他设备据此知道「云端没有了」
        //    （否则它们仍显示云标记，点开却 404）。
        set_blob_size(&conn, &uid, &content_hash, 0, &received_at)?;
    }

    tracing::info!(
        "book_blob delete: uid={} hash={} freed={}",
        uid,
        content_hash,
        freed
    );

    Ok(Json(serde_json::json!({
        "ok": true,
        "freed_bytes": freed,
    })))
}

// ══════════════════════════════════════════════════════════════════════
// 测试（记账与配额 —— 纯 SQL 逻辑，用临时库验证）
// ══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    const H1: &str = "0123456789abcdef";
    const H2: &str = "fedcba9876543210";

    fn setup() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn
    }

    /// 插一条书单（模拟端侧已 push）。
    fn seed_book(conn: &rusqlite::Connection, uid: &str, hash: &str, blob: i64, deleted: i64) {
        conn.execute(
            "INSERT INTO sync_book
               (user_id, content_hash, title, author, lang, chapter_count,
                size_bytes, blob_size, added_at, updated_at, deleted, received_at)
             VALUES (?1, ?2, 'T', '', 'en', 1, 100, ?3, '2026-10-07T00:00:00Z',
                     '2026-10-07T00:00:00Z', ?4, '2026-10-07T00:00:01.000Z')",
            params![uid, hash, blob, deleted],
        )
        .unwrap();
    }

    /// 🔴 **构造一次路由器** —— 这条断言守的是「路由表本身可构造」。
    ///
    /// 为什么需要它：axum 对**同一 path** 调用两次 `route()` 会 **panic**
    /// （"Overlapping method route"），而这个错误
    /// **`cargo check` 查不出来** —— 只有在真正构造 Router 时才炸，
    /// 也就是**服务启动时**。⇒ 没有这条断言，那个缺陷会一路活到部署。
    #[test]
    fn test_blob_routes_build_without_panic() {
        let r = blob_routes(BlobState::from_env());
        // `Router` 不实现 `Debug` 时无法 `assert!`，用 drop 表达「构造成功」
        drop(r);
    }

    /// 用量只算**未删除**的书。
    ///
    /// 🔑 这条守的是「删了书空间不减」这个用户**无法自救**的故障
    ///    （DELETE 端点失败时文件残留，若残留计入配额，用户只能等我们清理）。
    #[test]
    fn test_usage_excludes_deleted() {
        let conn = setup();
        seed_book(&conn, "u1", H1, 1_000, 0);
        seed_book(&conn, "u1", H2, 5_000, 1); // 已删（文件可能残留）
        assert_eq!(current_usage(&conn, "u1").unwrap(), 1_000, "只算未删除的");
    }

    /// 用户之间**互不影响**。
    #[test]
    fn test_usage_is_per_user() {
        let conn = setup();
        seed_book(&conn, "u1", H1, 1_000, 0);
        seed_book(&conn, "u2", H2, 7_000, 0);
        assert_eq!(current_usage(&conn, "u1").unwrap(), 1_000);
        assert_eq!(current_usage(&conn, "u2").unwrap(), 7_000);
        assert_eq!(current_usage(&conn, "nobody").unwrap(), 0, "陌生用户 = 0");
    }

    /// 记账要**同时推进 `received_at`** —— 否则其他设备看不到「云端有了」。
    #[test]
    fn test_set_blob_size_advances_received_at() {
        let conn = setup();
        seed_book(&conn, "u1", H1, 0, 0);
        let before: String = conn
            .query_row(
                "SELECT received_at FROM sync_book WHERE user_id='u1' AND content_hash=?1",
                params![H1],
                |r| r.get(0),
            )
            .unwrap();

        let n = set_blob_size(&conn, "u1", H1, 4096, "2099-01-01T00:00:00.000Z").unwrap();
        assert_eq!(n, 1, "应当更新到 1 行");

        let (blob, recv): (i64, String) = conn
            .query_row(
                "SELECT blob_size, received_at FROM sync_book
                  WHERE user_id='u1' AND content_hash=?1",
                params![H1],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(blob, 4096);
        assert_eq!(recv, "2099-01-01T00:00:00.000Z");
        assert!(recv > before, "🔴 必须推进（否则换机看不到云标记）");
    }

    /// 删书后上传要**被拒**（不能把已删的书传回来）。
    #[test]
    fn test_deleted_book_rejects_upload() {
        let conn = setup();
        seed_book(&conn, "u1", H1, 0, 1); // deleted = 1
        assert!(!book_row_exists(&conn, "u1", H1).unwrap());
        seed_book(&conn, "u1", H2, 0, 0);
        assert!(book_row_exists(&conn, "u1", H2).unwrap());
    }

    /// 🔴 同步通道**不能**改 `blob_size`（本表最重要的那条约束）。
    ///
    /// 手法：走真实的 `push_changes`（端侧口径），推一个 `BookInput`，
    /// 断言 `blob_size` **没变**；而端侧能推的 `title` 要变。
    #[test]
    fn test_push_does_not_clobber_blob_size() {
        let conn = setup();

        // 先用文件端点口径记账：云端已有 8192 字节
        //
        // ⚠️ 不插 `users` 行：`push_changes` 是**核心函数**（订阅校验在 handler 层），
        //    且 `sync_*` 表对 `users` **没有外键**（它们是同步副本，不是业务表的子表）。
        seed_book(&conn, "u1", H1, 8192, 0);

        // 端侧推一条同名书单（改了 title、并把旧的 updated_at 推上来）
        let input = crate::sync_handlers::PushInput {
            device_id: "devA".into(),
            review_events: vec![],
            user_words: vec![],
            article_reads: vec![],
            bookmarks: vec![],
            highlights: vec![],
            book_progress: vec![],
            books: vec![crate::sync_handlers::BookInput {
                content_hash: H1.into(),
                title: "新书名".into(),
                author: "A".into(),
                lang: "en".into(),
                chapter_count: 3,
                size_bytes: 999,
                added_at: "2026-10-07T00:00:00Z".into(),
                updated_at: "2099-01-01T00:00:00Z".into(), // 更新 ⇒ 触发 DO UPDATE
                deleted: 0,
            }],
        };
        crate::sync_handlers::push_changes(&conn, "u1", "devA", "2099-01-01T00:00:01.000Z", &input)
            .unwrap();

        let (title, blob): (String, i64) = conn
            .query_row(
                "SELECT title, blob_size FROM sync_book
                  WHERE user_id='u1' AND content_hash=?1",
                params![H1],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(title, "新书名", "端侧能推的字段应当更新");
        assert_eq!(
            blob, 8192,
            "🔴 blob_size 是服务端事实，push 绝不能覆盖它\
             （否则离线旧设备一次 push 就会把「云端有」标回「没有」）"
        );
    }
}
