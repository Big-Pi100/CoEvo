//! WebSocket Handler — 基于 select! 的消息与 ColdPath 并发处理
//!
//! ⚡ HotPath: 流式回复 → done 立即发送 → 不等概念提取
//! ❄️ ColdPath: 通过 channel 异步提取概念，不阻塞消息接收
//!
//! 鉴权: token 由首条消息 payload 传递（不出现在 URL 查询参数中）

use axum::extract::ws::{Message, WebSocket};
use chat_engine::llm_caller::{LlmCaller, LlmEvent};
use serde_json::json;
use tokio::sync::mpsc;
use std::sync::{LazyLock, Arc};
use std::time::Duration;
use std::future;

/// 全局踢下线通知: user_id → Notify
static KICK_NOTIFIERS: LazyLock<tokio::sync::Mutex<std::collections::HashMap<String, Arc<tokio::sync::Notify>>>> =
    LazyLock::new(|| tokio::sync::Mutex::new(std::collections::HashMap::new()));

/// 通知指定用户的所有旧 WS 连接被踢下线（新设备登录时调用）
pub async fn kick_user_connections(user_id: &str) {
    let mut lock = KICK_NOTIFIERS.lock().await;
    // remove 而非 get：销毁旧 Notify，杜绝 permit 残留
    // 当前在线 WS 收到 notify 被踢 → 新 WS 通过 or_insert_with 创建全新 Notify
    if let Some(notify) = lock.remove(user_id) {
        notify.notify_one();
    }
}

/// 内部使用，含可选 token 字段的反序列化结构
#[derive(serde::Deserialize)]
struct RawChatRequest {
    user_id: String,
    conversation_id: String,
    message: String,
    token: Option<String>,
}

/// B1: AI 回复 → 词汇激活（匹配 prebuilt_cards，纯规则，0 LLM）
/// 在 has_prebuilt_vocab 分支中调用，静默将匹配到的词汇加入 FSRS 复习队列
fn activate_from_ai_reply(conn: &rusqlite::Connection, user_id: &str, ai_reply: &str, subject: &str) {
    // 从 prebuilt_cards 加载该科目的所有词汇 front
    let mut stmt = match conn.prepare("SELECT front FROM prebuilt_cards WHERE subject = ?1") {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("[CP1] activate_from_ai_reply: prepare failed for subject={}: {}", subject, e);
            return;
        }
    };
    let fronts: Vec<String> = match stmt.query_map(rusqlite::params![subject], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            tracing::warn!("[CP1] activate_from_ai_reply: query failed for subject={}: {}", subject, e);
            return;
        }
    };
    if fronts.is_empty() {
        tracing::info!("[CP1] activate_from_ai_reply: no prebuilt cards for subject={}", subject);
        return;
    }
    tracing::info!("[CP1] activate_from_ai_reply: loaded {} vocab fronts for subject={}", fronts.len(), subject);

    // 用 HashSet 做 O(1) 匹配
    let vocab: std::collections::HashSet<String> = fronts.iter()
        .map(|f| f.to_lowercase()).collect();

    // 中文匹配：每个 prebuilt front 作为子串在 AI reply 中查找
    let matched: Vec<String> = if subject == "chinese" {
        fronts.iter()
            .filter(|f| f.len() >= 2 && ai_reply.contains(&f.to_lowercase()))
            .cloned()
            .collect()
    } else {
        // 英文匹配：按非英文字符分割后精确匹配
        ai_reply.split(|c: char| !c.is_ascii_alphabetic())
            .filter(|w| w.len() >= 2 && vocab.contains(&w.to_lowercase()))
            .map(|w| w.to_lowercase())
            .collect()
    };

    if matched.is_empty() {
        tracing::info!("[CP1] activate_from_ai_reply: no vocab matched in reply for subject={}, reply_len={}", subject, ai_reply.len());
        return;
    }
    tracing::info!("[CP1] activate_from_ai_reply: matched {} words for subject={}: {:?}", matched.len(), subject, matched);

    let language = if subject == "chinese" { "chinese" } else { "english" };
    let now = chrono::Utc::now().timestamp();

    for word in &matched {
        let word_lower = word.to_lowercase();

        // 去重
        let exists: bool = conn.query_row(
            "SELECT 1 FROM user_cards WHERE user_id = ?1 AND LOWER(front) = ?2 LIMIT 1",
            rusqlite::params![user_id, word_lower],
            |_| Ok(true),
        ).unwrap_or(false);
        if exists {
            continue;
        }

        activate_single_word(conn, user_id, &word_lower, language, now);
    }
}

/// B2: 用户输入 → 激活 + 验证（规则匹配 + LLM 判断）
/// 在 hot path 中调用，匹配已激活词汇后用 LLM 验证用法
/// 返回需要在 system context 中注入的纠正信息
pub async fn verify_user_input(
    conn: &rusqlite::Connection,
    user_id: &str,
    user_message: &str,
    language: &str,
    llm_config: &chat_engine::llm_caller::LlmConfig,
) -> Vec<serde_json::Value> {
    let mut corrections = Vec::new();

    let mut stmt = match conn.prepare("SELECT front FROM prebuilt_cards WHERE subject = ?1") {
        Ok(s) => s,
        Err(_) => return corrections,
    };
    let fronts: Vec<String> = match stmt.query_map(rusqlite::params![language], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(_) => return corrections,
    };
    if fronts.is_empty() { return corrections; }
    let vocab: std::collections::HashSet<String> = fronts.iter().map(|f| f.to_lowercase()).collect();

    let matched: Vec<String> = if language == "chinese" {
        fronts.iter()
            .filter(|f| f.len() >= 2 && user_message.contains(&f.to_lowercase()))
            .cloned()
            .collect()
    } else {
        user_message.split(|c: char| !c.is_ascii_alphabetic())
            .filter(|w| w.len() >= 2 && vocab.contains(&w.to_lowercase()))
            .map(|w| w.to_lowercase())
            .collect()
    };
    if matched.is_empty() { return corrections; }

    let now = chrono::Utc::now().timestamp();
    let today_start = now - (now % 86400);  // 今天的 00:00 UTC

    for word in &matched {

        // 查找用户是否已有该词的激活卡片
        let card_info: Option<(String, Option<i64>)> = conn.query_row(
            "SELECT c.id, cm.last_review FROM user_cards c \
             JOIN card_memory cm ON c.id = cm.user_card_id \
             WHERE c.user_id = ?1 AND LOWER(c.front) = ?2 AND c.language = 'english' \
             LIMIT 1",
            rusqlite::params![user_id, word],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        ).ok();

        match card_info {
            None => {
                // 未激活 → 首次激活（用户用出说明应认识）
                activate_single_word(conn, user_id, word, language, now);
            }
            Some((card_id, last_review)) => {
                // 已激活 → 每日频率控制
                if let Some(lr) = last_review {
                    if lr >= today_start {
                        continue; // 今天已经更新过，跳过
                    }
                }

                // 调 LLM 验证用法
                let verify_prompt = chat_engine::prompt_loader::get_verify("general").usage.clone();
                let full_prompt = if verify_prompt.is_empty() {
                    format!("判断用户是否正确使用了该单词。\n\nword: {}\nuser_context: {}", word, user_message)
                } else {
                    format!(
                        "{}\n\nword: {}\nuser_context: {}",
                        verify_prompt, word, user_message
                    )
                };

                let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
                match caller.generate("", &full_prompt).await {
                    Ok(response) => {
                        if let Ok(result) = serde_json::from_str::<serde_json::Value>(&response) {
                            let correct = result.get("correct").and_then(|v| v.as_bool()).unwrap_or(false);
                            if correct {
                                // 正确使用 → 更新 FSRS
                                let _ = conn.execute(
                                    "UPDATE card_memory SET reps = reps + 1, last_review = ?1, \
                                     due = ?1 + 86400 WHERE user_card_id = ?2 AND last_review < ?3",
                                    rusqlite::params![now, card_id, today_start],
                                );
                                tracing::info!("[CP1] verify_user_input: '{}' used correctly, FSRS updated", word);
                            } else {
                                // 用法错误 → 收集纠正信息
                                if let Some(hint) = result.get("correction_hint").and_then(|v| v.as_str()) {
                                    if !hint.is_empty() {
                                        corrections.push(serde_json::json!({
                                            "word": word,
                                            "correction_hint": hint,
                                            "reason": result.get("reason").and_then(|v| v.as_str()).unwrap_or("")
                                        }));
                                    }
                                }
                                tracing::info!("[CP1] verify_user_input: '{}' used incorrectly, will correct", word);
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("[CP1] verify_user_input: LLM call failed for '{}': {}", word, e);
                    }
                }
            }
        }
    }

    corrections
}

/// 激活单个词汇（B1/B2 共用）
fn activate_single_word(conn: &rusqlite::Connection, user_id: &str, word: &str, language: &str, now: i64) {
    let word_lower = word.to_lowercase();

    // 查找 prebuilt_card_id（按 subject 匹配）
    let prebuilt_id: Option<String> = conn.query_row(
        "SELECT id FROM prebuilt_cards WHERE LOWER(front) = ?1 AND subject = ?2 LIMIT 1",
        rusqlite::params![word_lower, language],
        |row| row.get(0),
    ).ok();

    // 从 prebuilt_language_cards 继承 level
    let level: String = prebuilt_id.as_ref().and_then(|id| {
        conn.query_row(
            "SELECT level FROM prebuilt_language_cards WHERE id = ?1",
            rusqlite::params![id],
            |row| row.get::<_, String>(0),
        ).ok()
    }).unwrap_or_else(|| "A1".to_string());

    let card_id = uuid::Uuid::new_v4().to_string();

    if let Err(e) = conn.execute(
        "INSERT INTO user_cards (id, user_id, plan_run_id, prebuilt_card_id, domain, front, status, language, level, created_at)
         VALUES (?1, ?2, '', ?3, ?4, ?5, 'pending', ?6, ?7, ?8)",
        rusqlite::params![card_id, user_id, prebuilt_id, language, word,
            language, level, now],
    ) {
        tracing::warn!("[CP1] activate_single_word: user_cards insert failed for '{}': {}", word, e);
        return;
    }

    if let Err(e) = conn.execute(
        "INSERT INTO card_memory (user_card_id, state, status, difficulty, stability, due, last_review, reps, lapses)
         VALUES (?1, 0, 'active', 0.3, 1.0, ?2, 0, 0, 0)",
        rusqlite::params![card_id, now],
    ) {
        tracing::warn!("[CP1] activate_single_word: card_memory insert failed for '{}': {}", word, e);
    }

    tracing::info!("[CP1] activate_single_word: activated word='{}', language={}, level={}", word, language, level);
}

pub async fn handle_ws(mut ws: WebSocket) {
    tracing::info!("handle_ws: new WebSocket connection established");
    // ColdPath 结果通道：后台 task 提取完概念后通过此通道发回
    let (cold_tx, mut cold_rx) = mpsc::channel::<(u32, Vec<serde_json::Value>)>(8);
    // CP2 通知通道：后台 task 更新 plan 后通知主循环发 WS 消息
    let (cp2_tx, mut cp2_rx) = mpsc::channel::<bool>(1);
    // CP2 繁忙信号：当 CP2 正在构建计划时，阻塞下一条用户消息
    let cp2_busy = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let cp2_done = Arc::new(tokio::sync::Notify::new());
    let mut turn_counter: u32 = 0;
    let mut next_turn_to_show: u32 = 0;
    let mut pending_candidates: std::collections::BTreeMap<u32, Vec<serde_json::Value>> = std::collections::BTreeMap::new();
    let mut token_verified = false;
    let mut kick_notify: Option<Arc<tokio::sync::Notify>> = None;
    let mut last_user_id = String::new();  // Phase 2: 用于 conversation_ended 成就检测
    let mut last_subject: Option<String> = None;  // 调试日志: 记录最后学科
    // 调试日志
    let mut debug_logger: Option<crate::debug_logger::DebugLogger> = None;

    // ⚡ Heartbeat: 每 60 秒发送 WS Ping 帧检测连接活性
    // 防止 ws.recv() 在连接被 Nginx/中间件静默切断后无限阻塞
    let mut heartbeat = tokio::time::interval(Duration::from_secs(60));
    // 跳过首次立即 tick（避免启动时立即触发 ping）
    heartbeat.tick().await;

    loop {
        tokio::select! {
            biased;
            // ── 接收用户消息（HotPath） ──
            msg = ws.recv() => {
                let text = match msg {
                    Some(Ok(Message::Text(t))) => t,
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => continue,
                };

                let turn_start = std::time::Instant::now();
                let raw_req: RawChatRequest = match serde_json::from_str(&text) {
                    Ok(r) => r,
                    Err(e) => {
                        if ws.send(Message::Text(
                            json!({"type":"error","content": format!("Invalid request: {}", e)}).to_string().into()
                        )).await.is_err() { break; }
                        continue;
                    }
                };

                // ── CP2 繁忙等待：仅在 CP2 正在运行时阻塞用户消息 ──
                if cp2_busy.load(std::sync::atomic::Ordering::Acquire) {
                    cp2_done.notified().await;
                }

                // ── 鉴权：首条消息必须携带有效 token ──
                if !token_verified {
                    match &raw_req.token {
                        Some(token) => {
                            let conn = crate::db_pool::get_conn();
                            if crate::auth::verify_token(&conn, &raw_req.user_id, token) {
                                token_verified = true;
                                // 注册踢下线通知（单设备登录强制）
                                let mut lock = KICK_NOTIFIERS.lock().await;
                                let notify = lock.entry(raw_req.user_id.clone())
                                    .or_insert_with(|| Arc::new(tokio::sync::Notify::new()))
                                    .clone();
                                kick_notify = Some(notify);
                            } else {
                                let _ = ws.send(Message::Text(
                                    json!({"type":"error","content":"invalid_token"}).to_string().into()
                                )).await;
                                continue;
                            }
                        }
                        None => {
                            let _ = ws.send(Message::Text(
                                json!({"type":"error","content":"missing_token"}).to_string().into()
                            )).await;
                            continue;
                        }
                    }
                }

                let chat_req = shared_types::conversation::ChatRequest {
                    user_id: raw_req.user_id,
                    conversation_id: raw_req.conversation_id,
                    message: raw_req.message,
                    token: raw_req.token.clone(),
                };
                last_user_id = chat_req.user_id.clone();  // Phase 2: 记录最后活跃用户

                // ── 调试日志：session_start + tracker_check ──
                {
                    let is_tracked = crate::debug_trackers_cache::is_tracked(&chat_req.user_id)
                        || crate::debug_trackers_cache::is_conv_tracked(&chat_req.conversation_id);
                    if is_tracked {
                        match crate::debug_logger::DebugLogger::create(&chat_req.conversation_id).await {
                            Ok(logger) => {
                                debug_logger = Some(logger);
                                // 立即写入 debug_logs DB 表，让管理后台能第一时间看到
                                let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
                                let log_path = format!("data/debug_logs/{}/{}.jsonl",
                                    today, chat_req.conversation_id);
                                if let Err(e) = crate::db_pool::get_conn().execute(
                                    "INSERT OR REPLACE INTO debug_logs
                                     (id, conversation_id, user_id, subject, date, log_file_path,
                                      entry_count, file_size_bytes, created_at)
                                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7)",
                                    rusqlite::params![
                                        chat_req.conversation_id,
                                        chat_req.conversation_id,
                                        Some(&chat_req.user_id),
                                        last_subject.as_deref(), // subject
                                        today,
                                        log_path,
                                        chrono::Utc::now().timestamp(),
                                    ],
                                ) {
                                    tracing::warn!("Failed to insert debug_logs record at creation: {}", e);
                                }
                                if let Some(ref l) = debug_logger {
                                    let _ = l.log("base", "session_start", json!({
                                        "conversation_id": chat_req.conversation_id,
                                        "user_id": chat_req.user_id,
                                        "tracked": true,
                                    })).await;
                                }
                                tracing::info!("Debug logging started for conv={}", chat_req.conversation_id);
                            }
                            Err(e) => tracing::warn!("Failed to create debug logger: {}", e),
                        }
                    } else {
                        tracing::debug!("No debug tracking for user={}", chat_req.user_id);
                    }
                }

                // 检查订阅状态
                {
                    let conn = crate::db_pool::get_conn();
                    let expires: Option<String> = conn.query_row(
                        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
                        rusqlite::params![chat_req.user_id],
                        |row| row.get(0),
                    ).ok().flatten();
                    let now_ts = chrono::Utc::now().timestamp();
                    let expired = match &expires {
                        Some(e) => {
                            // 兼容 "YYYY-MM-DD" 格式：自动补全为 RFC3339
                            let normalized = if e.len() == 10 && e.as_bytes().get(4) == Some(&b'-') {
                                format!("{}T00:00:00Z", e)
                            } else {
                                e.clone()
                            };
                            chrono::DateTime::parse_from_rfc3339(&normalized)
                                .map(|dt| dt.timestamp() < now_ts)
                                .unwrap_or(true) // 解析失败视为已过期
                        }
                        None => true, // 无记录 = 未付费
                    };
                    if expired {
                        let msg = if expires.is_some() {
                            "subscription_expired".to_string()
                        } else {
                            "subscription_required".to_string()
                        };
                        if ws.send(Message::Text(
                            json!({"type":"error","content": msg}).to_string().into()
                        )).await.is_err() { break; }
                        continue;
                    }
                }

                // 保存用户消息
                let now_str = chrono::Utc::now().timestamp();
                {
                    let conn = crate::db_pool::get_conn();
                    // 确认对话存在：INSERT OR IGNORE + 如已软删除则恢复
                    let _ = conn.execute(
                        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
                        rusqlite::params![chat_req.conversation_id, chat_req.user_id, now_str],
                    );
                    let _ = conn.execute(
                        "UPDATE conversations SET deleted_at = NULL WHERE id = ?1 AND deleted_at IS NOT NULL",
                        rusqlite::params![chat_req.conversation_id],
                    );
                    tracing::info!("WS conversation confirmed: id={}", chat_req.conversation_id);
                    let _ = conn.execute(
                        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'user', ?3, ?4)",
                        rusqlite::params![uuid::Uuid::new_v4().to_string(), chat_req.conversation_id, chat_req.message, now_str],
                    );
                }

                let llm_config = crate::llm::get_config();
                let (tx, mut rx) = mpsc::channel::<LlmEvent>(256);

                // 加载最近 5 轮对话历史作为上下文
                let history = {
                    let conn = crate::db_pool::get_conn();
                    let mut stmt = conn.prepare(
                        "SELECT role, content FROM conversation_turns
                         WHERE conversation_id = ?1
                         ORDER BY created_at DESC LIMIT 5"
                    ).unwrap();
                    // 反转: 从旧到新
                    let mut turns: Vec<(String, String)> = stmt.query_map(
                        rusqlite::params![chat_req.conversation_id],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                    ).unwrap().filter_map(|r| r.ok()).collect();
                    turns.reverse();
                    turns
                };
                tracing::info!("WS loaded {} turns for conv={}", history.len(), chat_req.conversation_id);

                // ── 查询学习计划，判定生命周期状态 + 管线 ──
                let (system_prompt, plan_context, debug_plan_info) = {
                    let conn = crate::db_pool::get_conn();
                    let plan_id = crate::plan_handler::resolve_plan_id(&conn, &chat_req.conversation_id).unwrap_or_default();
                    let (domain, mode, ctx) = crate::plan_handler::build_plan_context(&conn, &plan_id, &chat_req.conversation_id);
                    tracing::info!("WS plan context: domain={}, mode={}", domain, mode);
                    // 记录 prompt 来源（供 e2e 测试验证）
                    crate::plan_handler::log_prompt_source(&format!("{}/{}", domain, mode));
                    let templates = chat_engine::prompt_loader::get_chat(&domain);
                    let selected_mode = mode.clone();
                    let sp = match mode.as_str() {
                        "reading-nursery" | "reading_nursery" => {
                            let p = templates.reading_nursery.clone();
                            if !p.is_empty() { p } else { templates.reading.clone() }
                        }
                        "reading-primary" | "reading_primary" => {
                            let p = templates.reading_primary.clone();
                            if !p.is_empty() { p } else { templates.reading.clone() }
                        }
                        "reading-secondary" | "reading_secondary" | "reading" => {
                            let p = templates.reading_secondary.clone();
                            if !p.is_empty() { p } else { templates.reading.clone() }
                        }
                        "structured" => templates.structured.clone(),
                        _ => templates.free.clone(),
                    };
                    // 将路由上下文合并到计划上下文中
                    let full_ctx = if ctx.is_empty() { String::new() } else { ctx.clone() };
                    (sp, full_ctx, (domain, selected_mode, ctx.len()))
                };

                // 记录学科（用于调试日志的 subject 字段）
                if !debug_plan_info.0.is_empty() {
                    last_subject = Some(debug_plan_info.0.clone());
                }

                // ── 调试日志：plan_context_built + system_prompt_selected ──
                if let Some(ref logger) = debug_logger {
                    let _ = logger.log("base", "plan_context_built", json!({
                        "domain": debug_plan_info.0,
                        "mode": debug_plan_info.1,
                        "context_length": debug_plan_info.2,
                    })).await;
                    let _ = logger.log("base", "system_prompt_selected", json!({
                        "domain": debug_plan_info.0,
                        "mode": debug_plan_info.1,
                        "char_count": system_prompt.len(),
                        "text_preview": &system_prompt,
                    })).await;
                }

                // ── 构建 user_content（对话历史 + 计划上下文 + 当前消息） ──
                let mut user_content = String::new();
                let mut history_section_length = 0usize;
                let max_turns: usize = crate::app_config_cache::get("prompt.history_max_turns").await
                    .and_then(|v| v.parse().ok()).unwrap_or(10);
                let max_chars: usize = crate::app_config_cache::get("prompt.history_max_chars").await
                    .and_then(|v| v.parse().ok()).unwrap_or(5000);
                if history.len() > 1 {
                    let context = &history[..history.len() - 1];
                    // 滑动窗口: 保留最近 10 轮, 总长度 ≤5000 字, 不截断单条
                    let mut lines: Vec<String> = Vec::new();
                    let mut total = 0usize;
                    let mut turns = 0usize;
                    for (role, content) in context.iter().rev() {
                        let label = if role == "user" { "用户" } else { "AI" };
                        let line = format!("\n{}: {}", label, content);
                        let next = total + line.len();
                        if next > max_chars || turns >= max_turns { break; }
                        total = next;
                        turns += 1;
                        lines.push(line);
                    }
                    if !lines.is_empty() {
                        lines.reverse();
                        user_content.push_str("\n\n### 对话历史");
                        for l in &lines {
                            user_content.push_str(l);
                            history_section_length += l.len();
                        }
                    }
                }
                user_content.push_str(&format!("\n\n### 当前对话\n用户: {}", chat_req.message));
                if !plan_context.is_empty() {
                    user_content.push_str(&plan_context);
                }

                // ── 调试日志：history_loaded + user_content_built ──
                if let Some(ref logger) = debug_logger {
                    let history_total_chars: usize = history.iter().map(|(_, c)| c.len()).sum();
                    let history_total_turns = history.len();
                    let original_total_chars: usize = history.iter().map(|(_, c)| c.len()).sum();
                    let _ = logger.log("base", "history_loaded", json!({
                        "total_turns": history_total_turns,
                        "total_chars": history_total_chars,
                        "original_chars": original_total_chars,
                        "truncated_turns": history_total_turns > max_turns,
                        "truncated_chars": history_total_chars > max_chars,
                        "max_turns": max_turns,
                        "max_chars": max_chars,
                        "history": history.iter().map(|(r,c)| format!("{}: {}", r, c)).collect::<Vec<_>>(),
                    })).await;
                    let _ = logger.log("base", "user_content_built", json!({
                        "content_length": user_content.len(),
                        "plan_context_length": plan_context.len(),
                        "history_section_length": history_section_length,
                        "text_preview": &user_content,
                    })).await;
                }

                // 记录 LLM 输入（供 e2e 测试捕获）
                crate::plan_handler::log_llm_input(&system_prompt, &user_content);

                // 后台流式生成 LLM 回复
                let cfg = llm_config.clone();
                let tx2 = tx.clone();
                tokio::spawn(async move {
                    let mut caller = LlmCaller::new(cfg);
                    if let Err(e) = caller.stream_generate(&system_prompt, &user_content, tx2).await {
                        let _ = tx.send(LlmEvent::Done(format!("[LLM 暂时不可用: {}]", e))).await;
                    }
                });

                // ⚡ HotPath: 等待 LLM 回复，流式转发
                let mut final_reply = String::new();
                let mut got_done = false;
                let mut is_planning = false;
                let mut ws_disconnected = false;
                loop {
                    match tokio::time::timeout(Duration::from_secs(60), rx.recv()).await {
                        Ok(Some(LlmEvent::Thinking)) => {
                            if ws.send(Message::Text(json!({"type":"thinking"}).to_string().into())).await.is_err() {
                                ws_disconnected = true;
                                break;
                            }
                        }
                        Ok(Some(LlmEvent::Token(content))) => {
                            final_reply.push_str(&content);
                            if is_planning {
                                // 计划生成中，不再转发原始 token
                            } else if final_reply.contains("<plan_update") || final_reply.contains("<reading_update") {
                                is_planning = true;
                                if ws.send(Message::Text(json!({
                                    "type":"planning"
                                }).to_string().into())).await.is_err() {
                                    ws_disconnected = true;
                                    break;
                                }
                            } else {
                                if ws.send(Message::Text(json!({"type":"token","content":content}).to_string().into())).await.is_err() {
                                    ws_disconnected = true;
                                    break;
                                }
                            }
                        }
                        Ok(Some(LlmEvent::Done(reply))) => {
                            final_reply = reply;
                            got_done = true;
                            break;
                        }
                        Ok(None) | Err(_) => break,
                    }
                }
                if ws_disconnected {
                    tracing::warn!("WS send failed during streaming — connection lost");
                    break;
                }
                if !got_done && final_reply.is_empty() {
                    final_reply = "[LLM 响应超时]".to_string();
                }

                // ── 解析学习计划更新（共用 plan_handler 模块） ──
                let mut plan_updated;
                {
                    let conn = crate::db_pool::get_conn();
                    let plan_id = crate::plan_handler::resolve_plan_id(&conn, &chat_req.conversation_id).unwrap_or_default();
                    let result = crate::plan_handler::handle_plan_update(
                        &conn, &final_reply, &plan_id, &chat_req.conversation_id, &chat_req.user_id,
                    );
                    final_reply = result.cleaned_reply;
                    plan_updated = result.plan_updated;

                    if result.is_new_plan {
                        // ── 调试日志：plan_created ──
                        if let Some(ref logger) = debug_logger {
                            let _ = logger.log("cp1", "plan_created", json!({
                                "trigger": "goal",
                                "domain": debug_plan_info.0,
                            })).await;
                        }
                        if let Some(ref plan) = result.task_status {
                            final_reply = crate::plan_handler::render_plan(plan);
                        }
                    }

                    // 成就检测已由 TOML 引擎 + AppEvent::PlanCompleted 事件总线统一处理
                    // 见 plan_handler.rs:215
                }

                // 保存 assistant 回复（final_reply 已清理/渲染）
                // ── 调试日志：llm_reply ──
                if let Some(ref logger) = debug_logger {
                    let _ = logger.log("base", "llm_reply", json!({
                        "reply_length": final_reply.len(),
                        "reply_preview": &final_reply,
                    })).await;
                }
                let now_str = chrono::Utc::now().timestamp();
                {
                    let conn = crate::db_pool::get_conn();
                    let _ = conn.execute(
                        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'assistant', ?3, ?4)",
                        rusqlite::params![uuid::Uuid::new_v4().to_string(), chat_req.conversation_id, final_reply, now_str],
                    );
                    let _ = conn.execute(
                        "UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
                        rusqlite::params![chat_req.conversation_id],
                    );
                }

                // ⚡ HotPath: 发 done — 失败则连接已断，跳过后序处理
                if ws.send(Message::Text(json!({
                    "type": "done",
                    "reply": final_reply,
                }).to_string().into())).await.is_err() {
                    tracing::warn!("WS send(done) failed — connection lost");
                    break;
                }

                // ⚡ 从 final_reply 中检测 **goal 标记 → 立即创建学习计划
                // 每次 LLM 回复后检查，不依赖 CP2 的二次 LLM 调用
                if !plan_updated && final_reply.contains("**goal") && final_reply.contains("✅ 已完成") {
                    let conv_for_plan = chat_req.conversation_id.clone();
                    let uid = chat_req.user_id.clone();
                    let extra = "";
                    if crate::plan_handler::force_plan_creation(&uid, &conv_for_plan, extra).await {
                        plan_updated = true;
                        tracing::info!("Plan creation triggered by **goal badge in LLM reply");
                    }
                }

                // ── 代码层兜底：若 LLM 未处理回退请求，自动回退（auto_revert 已迁移） ──
                if !plan_updated {
                    let revert_conn = crate::db_pool::get_conn();
                    let revert_plan_id = crate::plan_handler::resolve_plan_id(&revert_conn, &chat_req.conversation_id).unwrap_or_default();
                    if crate::plan_handler::auto_revert(&revert_conn, &revert_plan_id, &chat_req.message) {
                        plan_updated = true;
                        tracing::info!("Revert signal detected: {}", &chat_req.message[..chat_req.message.len().min(80)]);
                    }
                }

                // ── /plan 命令：强制创建计划 ──
                // 支持 /plan 或 /plan 学习二次函数（参数作为用户意图追加到对话上下文）
                if !plan_updated && chat_req.message.trim().starts_with("/plan") {
                    let extra = chat_req.message.trim().strip_prefix("/plan").map(|s| s.trim()).unwrap_or("");
                    if !extra.is_empty() {
                        // 将参数作为用户意图注入对话文本的前面
                        tracing::info!("Plan creation with intent: {}", extra);
                    }
                    if crate::plan_handler::force_plan_creation(&chat_req.user_id, &chat_req.conversation_id, extra).await {
                        plan_updated = true;
                        tracing::info!("Plan creation triggered by /plan command");
                    }
                }

                // 通知前端刷新计划
                if plan_updated
                    && ws.send(Message::Text(json!({
                        "type": "plan_updated",
                    }).to_string().into())).await.is_err() {
                        tracing::warn!("WS send(plan_updated) failed — connection lost");
                        break;
                    }

                // Phase 2: 轮次成就检测（每轮 done 后检查全部成就，通知前端）
                {
                    let conn = crate::db_pool::get_conn();
                    let ctx = crate::achievement_engine::build_context(&conn, &chat_req.user_id);
                    let engine = crate::achievement_engine::get();
                    let new_achievements = engine.check_and_persist(&conn, &ctx);
                    if !new_achievements.is_empty() {
                        tracing::info!(
                            "WS turn achievements: user={} count={} keys={:?}",
                            chat_req.user_id, new_achievements.len(),
                            new_achievements.iter().map(|a| a.achievement_key.as_str()).collect::<Vec<_>>()
                        );
                        if ws.send(Message::Text(
                            json!({"type": "achievements", "achievements": new_achievements}).to_string().into()
                        )).await.is_err() {
                            tracing::warn!("WS send(achievements) failed");
                        }
                    }
                }

                let current_turn = turn_counter;
                turn_counter += 1;

                // ── 生产环境 metrics 日志 ──
                let turn_latency = turn_start.elapsed();
                let turn_card_count: i64 = {
                    let conn = crate::db_pool::get_conn();
                    conn.query_row(
                        "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active'",
                        rusqlite::params![&chat_req.user_id],
                        |row| row.get(0),
                    ).unwrap_or(0)
                };
                tracing::info!(
                    turn = current_turn,
                    latency_ms = turn_latency.as_millis() as i64,
                    reply_chars = final_reply.len(),
                    prompt_chars_est = chat_req.message.len() + chat_req.message.len(),
                    completion_chars_est = final_reply.len(),
                    plan_updated = plan_updated,
                    card_count = turn_card_count,
                    user_id = &chat_req.user_id,
                    "WS turn completed"
                );

                // ❄️ ColdPath: 扔到后台 task，不阻塞消息接收
                let cold_tx = cold_tx.clone();
                let _cold_turn = current_turn;
                // 获取 domain 用于概念提取管线路由
                let conv_id = &chat_req.conversation_id;
                let (extract_domain, extract_mode, extract_plan_ctx) = {
                    let conn = crate::db_pool::get_conn();
                    let pid = crate::plan_handler::resolve_plan_id(&conn, conv_id).unwrap_or_default();
                    crate::plan_handler::build_plan_context(&conn, &pid, conv_id)
                };
                tracing::info!("[CP1] build_plan_context: domain={}, mode={}, plan_ctx=[{}]",
                    extract_domain, extract_mode, extract_plan_ctx);
                // CP2 需要 final_reply，但 CP1 spawn 会 move 走它，提前 clone
                let cp2_reply = final_reply.clone();
                // ❄️ ColdPath 1: 概念提取 — 仅在 CP2 创建 plan 后运行
                // 每轮先检查 plan_runs 是否存在，有 plan 才走 LLM 提取
                let user_id = chat_req.user_id.clone();
                let msg = chat_req.message.clone();
                let config = llm_config.clone();
                let cold_tx = cold_tx.clone();
                let cold_turn = current_turn;
                let history_clone = history.clone();
                let ctx = String::new();  // CP1 不需要 plan_context
                let ed = extract_domain.clone();
                let fr = final_reply.clone();
                let conv_id_cp1 = chat_req.conversation_id.clone();
                tokio::spawn(async move {
                    let result: Option<Vec<String>> = 'db: {
                        let conn = crate::db_pool::get_conn();

                        let ef: Vec<String> = {
                            let mut stmt = match conn.prepare(
                                "SELECT LOWER(COALESCE(c.front, pc.front)) FROM user_cards c \
                                 LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id \
                                 JOIN card_memory cm ON c.id=cm.user_card_id \
                                 WHERE c.user_id = ?1 AND cm.status = 'active' \
                                   AND c.plan_run_id = (SELECT id FROM plan_runs WHERE conversation_id = ?2) \
                                   AND c.task_key = (SELECT task_key FROM user_plan_progress WHERE plan_id = c.plan_run_id AND status = 'in_progress' LIMIT 1)"
                            ) {
                                Ok(s) => s,
                                Err(_) => break 'db None,
                            };
                            let rows = match stmt.query_map(
                                rusqlite::params![user_id, conv_id_cp1],
                                |row| row.get::<_, String>(0)
                            ) {
                                Ok(r) => r,
                                Err(_) => break 'db None,
                            };
                            rows.filter_map(|r| r.ok()).collect()
                        };

                        Some(ef)
                    }; // conn dropped here — safe to .await now

                    let existing_fronts = match result {
                        Some(v) => v,
                        None => {
                            let _ = cold_tx.send((cold_turn, vec![])).await;
                            return;
                        }
                    };

                    // CP1 必须在 CP2 创建计划之后才运行 — 检查 plan_run 是否存在
                    let has_plan: bool = {
                        let conn_check = crate::db_pool::get_conn();
                        conn_check.query_row(
                            "SELECT 1 FROM plan_runs WHERE conversation_id = ?1 LIMIT 1",
                            rusqlite::params![&conv_id_cp1],
                            |_| Ok(true),
                        ).unwrap_or(false)
                    };
                    // 已预制词典的科目（english/chinese）跳过 CP1，避免重复提取和降质
                    let has_prebuilt_vocab = ed == "english" || ed == "chinese";
                    if !has_plan || has_prebuilt_vocab {
                        let skip_reason = if !has_plan { "no plan".to_string() } else { format!("prebuilt vocab subject={}", ed) };
                        tracing::info!("CP1 skipped for turn {}: {}", cold_turn, skip_reason);
                        // ── 调试日志：cp1_skipped ──
                        if let Ok(cp1_logger) = crate::debug_logger::DebugLogger::create(&conv_id_cp1).await {
                            let _ = cp1_logger.log("cp1", "cp1_skipped", json!({
                                "reason": skip_reason,
                                "turn": cold_turn,
                                "domain": ed,
                            })).await;
                            let _ = cp1_logger.close().await;
                        }
                        // AI 回复中出现预置词汇时静默激活（仅限有 plan 的预置词库科目）
                        if has_prebuilt_vocab && has_plan {
                            let conn_activate = crate::db_pool::get_conn();
                            activate_from_ai_reply(&conn_activate, &user_id, &fr, &ed);
                        }
                        let _ = cold_tx.send((cold_turn, vec![])).await;
                        return;
                    }

                    tracing::info!("CP1 starting concept extraction for turn {}", cold_turn);

                    // 从配置读取概念提取上限
                    let max_concepts = {
                        let conn = crate::db_pool::get_conn();
                        crate::app_config_cache::get_sync(&conn, "prompt.concept_extract_max")
                            .ok()
                            .flatten()
                            .and_then(|v| v.parse::<usize>().ok())
                            .unwrap_or(5)
                    };

                    // 30 秒超时：防止 LLM 挂起导致 turn 永远不到达
                    let extraction = match tokio::time::timeout(
                        Duration::from_secs(30),
                        chat_engine::concept_extractor::extract_concepts(
                            &user_id, &msg, &fr,
                            &existing_fronts, &config,
                            &history_clone, &ed, &ctx, max_concepts,
                        ),
                    ).await {
                        Ok(e) => e,
                        Err(_) => {
                            tracing::warn!("ColdPath concept extraction timed out for turn {}", cold_turn);
                            let _ = cold_tx.send((cold_turn, vec![])).await;
                            return;
                        }
                    };

                    let candidate_count = extraction.candidates.len();
                    tracing::info!("CP1 extracted {} candidates for turn {}", candidate_count, cold_turn);
                    // ── 调试日志：cp1_concept_extraction ──
                    if let Ok(cp1_log) = crate::debug_logger::DebugLogger::create(&conv_id_cp1).await {
                        let _ = cp1_log.log("cp1", "cp1_concept_extraction", json!({
                            "turn": cold_turn,
                            "candidates_count": candidate_count,
                            "domain": ed,
                        })).await;
                        let _ = cp1_log.close().await;
                    }

                    // 概念提取 → 批量入库 (status='pending')，返回 card_id 供前端 PATCH
                    let pending_candidates: Vec<serde_json::Value> = {
                        let conn = crate::db_pool::get_conn();
                        // 查询 plan_run_id 和当前 task_key（如无则创建临时 plan_run）
                        let (plan_run_id, cp1_task_key): (String, String) = match conn.query_row(
                            "SELECT pr.id, COALESCE((SELECT task_key FROM user_plan_progress WHERE plan_id = pr.id AND status = 'in_progress' LIMIT 1), '') 
                             FROM plan_runs pr WHERE pr.conversation_id = ?1 LIMIT 1",
                            rusqlite::params![&conv_id_cp1],
                            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                        ) {
                            Ok(v) => v,
                            Err(_) => {
                                // 无 plan_run 时创建临时记录（CP1 场景）
                                let tmp_id = uuid::Uuid::new_v4().to_string();
                                let now = chrono::Utc::now().timestamp();
                                let _ = conn.execute(
                                    "INSERT INTO plan_runs (id, user_id, conversation_id, domain, created_at, updated_at)
                                     VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                                    rusqlite::params![tmp_id, user_id, conv_id_cp1, ed, now],
                                );
                                (tmp_id, String::new())
                            }
                        };
                        // 开启事务：确保 user_cards + 子表 + card_memory 原子写入
                        conn.execute_batch("BEGIN").ok();
                        let r: Vec<serde_json::Value> = extraction.candidates.iter().map(|c| {
                            let card_id = uuid::Uuid::new_v4().to_string();
                            let now = chrono::Utc::now().timestamp();
                            tracing::info!("[CP1] inserting candidate: front={}, domain={}", c.front, c.domain);
                            // 1. 写入 user_cards（主表）
                            // domain='language' 时记录 language 列，供语言 tab 查询
                            let card_language = match c.domain.as_str() {
                                "language" => Some("english"),
                                _ => None,
                            };
                            if let Err(e) = conn.execute(
                                "INSERT INTO user_cards (id, user_id, plan_run_id, prebuilt_card_id, domain, front, status, task_key, language, created_at)
                                 VALUES (?1, ?2, ?3, NULL, ?4, ?5, 'pending', ?6, ?7, ?8)",
                                rusqlite::params![card_id, user_id, plan_run_id, c.domain, c.front,
                                    if cp1_task_key.is_empty() { None } else { Some(&cp1_task_key) },
                                    card_language, now],
                            ) {
                                tracing::warn!("[CP1] user_cards insert failed: {}", e);
                                return json!({"id": "", "error": format!("user_cards: {}", e)});
                            }
                            // 2. 根据 domain 写入对应的 user_*_cards 子表
                            //    c.back 是 V4 格式的 JSON blob，解析后提取对应字段
                            let back_val: serde_json::Value = serde_json::from_str(&c.back).unwrap_or(serde_json::Value::Null);
                            let sub_result = match c.domain.as_str() {
                                "science" => {
                                    let def = back_val.get("definition").and_then(|v| v.as_str()).unwrap_or(&c.back);
                                    conn.execute(
                                        "INSERT INTO user_science_cards (id, definition, source) VALUES (?1, ?2, ?3)",
                                        rusqlite::params![card_id, def, c.source_sentence],
                                    )
                                },
                                "language" => {
                                    let pron = back_val.get("pronunciation").and_then(|v| v.as_str()).unwrap_or("");
                                    let phrases = back_val.get("related_phrases").and_then(|v| v.as_str()).unwrap_or("");
                                    conn.execute(
                                        "INSERT INTO user_language_cards (id, pronunciation, related_phrases) VALUES (?1, ?2, ?3)",
                                        rusqlite::params![card_id, pron, phrases],
                                    )
                                },
                                "literature" => {
                                    let ft = back_val.get("full_text").and_then(|v| v.as_str()).unwrap_or(&c.back);
                                    conn.execute(
                                        "INSERT INTO user_literature_cards (id, full_text) VALUES (?1, ?2)",
                                        rusqlite::params![card_id, ft],
                                    )
                                },
                                "humanities" => {
                                    let body = back_val.get("body").and_then(|v| v.as_str()).unwrap_or(&c.back);
                                    conn.execute(
                                        "INSERT INTO user_humanities_cards (id, body) VALUES (?1, ?2)",
                                        rusqlite::params![card_id, body],
                                    )
                                },
                                _ => {
                                    // 未知 domain：存入 science 子表作为 fallback（definition 最通用）
                                    let fallback = back_val.get("definition")
                                        .or_else(|| back_val.get("body"))
                                        .or_else(|| back_val.get("full_text"))
                                        .and_then(|v| v.as_str())
                                        .unwrap_or(&c.back);
                                    conn.execute(
                                        "INSERT INTO user_science_cards (id, definition, source) VALUES (?1, ?2, ?3)",
                                        rusqlite::params![card_id, fallback, c.source_sentence],
                                    )
                                }
                            };
                            if let Err(e) = sub_result {
                                tracing::warn!("[CP1] sub-table insert failed for domain={}, front={}: {}", c.domain, c.front, e);
                            }
                            // 3. card_memory: 状态数据（user_card_id 指向 user_cards.id）
                            let _ = conn.execute(
                                "INSERT INTO card_memory (card_id, user_card_id, state, status, difficulty, stability, due, last_review, reps, lapses)
                                 VALUES (?1, ?2, 0, 'pending', 0.3, 1.0, ?3, 0, 0, 0)",
                                rusqlite::params![card_id, card_id, now],
                            );
                            // 为弹窗提取显示用的 back（从 V4 JSON blob 提取主字段）
                            let display_back = back_val.get("definition")
                                .or_else(|| back_val.get("body"))
                                .or_else(|| back_val.get("full_text"))
                                .and_then(|v| v.as_str())
                                .unwrap_or(if let Some(def) = back_val.get("definitions") {
                                    // language: 取第一个释义的 meaning
                                    def.as_array().and_then(|a| a.first())
                                        .and_then(|f| f.get("meaning"))
                                        .and_then(|m| m.as_str())
                                        .unwrap_or(&c.back)
                                } else { &c.back });
                            json!({"id": card_id, "front": c.front, "back": display_back,
                                   "source_sentence": c.source_sentence, "domain": &c.domain})
                        }).collect();
                        conn.execute_batch("COMMIT").ok();
                        r
                    };
                    tracing::info!("CP1 inserted {} pending cards for turn {}", pending_candidates.len(), cold_turn);
                    // ── 调试日志：cp1_cards_inserted ──
                    if let Ok(cp1_log) = crate::debug_logger::DebugLogger::create(&conv_id_cp1).await {
                        let _ = cp1_log.log("cp1", "cp1_cards_inserted", json!({
                            "count": pending_candidates.len(),
                        })).await;
                        let _ = cp1_log.close().await;
                    }
                    // 成就检测：卡片创建后触发 card_created 事件
                    if !pending_candidates.is_empty() {
                        let conn = crate::db_pool::get_conn();
                        crate::achievement_engine::publish(&conn, crate::achievement_engine::AppEvent::CardCreated { user_id });
                    }
                    let send_result = cold_tx.send((cold_turn, pending_candidates)).await;
                    if let Err(e) = send_result {
                        tracing::warn!("[CP1] cold_tx.send failed: {:?}", e);
                    }
                });

                // ❄️ ColdPath 2: 计划进度分析（轻量，每轮检测）
                // 每轮判断 teacher 最后一轮回复（final_reply），仅单轮 LLM 调用：
                //   1. 无 plan → 检测 teacher 是否自然引入学习任务
                //   2. 有 plan → 检测 teacher 是否标记当前任务完成
                // HotPath（XML 标签）已处理时跳过，避免重复更新
                // 改用 tokio::spawn 而非 std::thread::spawn，避免在 1GB VPS 上创建 OS 线程 + tokio 运行时
                if !plan_updated && turn_counter > 0 {
                    let conv_id = chat_req.conversation_id.clone();
                    let uid = chat_req.user_id.clone();
                    let cfg = llm_config.clone();
                    let reply = cp2_reply;
                    let cp2_notify = cp2_tx.clone();
                    let cp2_busy_flag = cp2_busy.clone();
                    let cp2_done_signal = cp2_done.clone();
                    // resolve plan_id before spawning
                    let cp2_plan_id = {
                        let conn = crate::db_pool::get_conn();
                        crate::plan_handler::resolve_plan_id(&conn, &conv_id).unwrap_or_default()
                    };
                    // 标记 CP2 繁忙：下一条用户消息需等待 CP2 完成
                    cp2_busy.store(true, std::sync::atomic::Ordering::Release);
                    tokio::spawn(async move {
                        let mut caller = chat_engine::llm_caller::LlmCaller::new(cfg);
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        let updated = crate::plan_handler::analyze_turn_progress(
                            &cp2_plan_id, &conv_id, &uid, &mut caller, &reply,
                        ).await;
                        if updated {
                            let _ = cp2_notify.send(true).await;
                        }
                        // CP2 完成：唤醒可能正在阻塞的用户消息
                        cp2_busy_flag.store(false, std::sync::atomic::Ordering::Release);
                        cp2_done_signal.notify_waiters();
                    });
                }
            }

            // ── 踢下线信号（单设备登录强制） ──
            _ = async {
                if let Some(ref n) = kick_notify { n.notified().await } else { future::pending().await }
            } => {
                let _ = ws.send(Message::Text(
                    json!({"type":"kicked","content":"您的账号已在其他设备登录，当前连接已断开"}).to_string().into()
                )).await;
                break;
            }

            // ⚡ Heartbeat: 发送 WS Ping 帧检测连接活性
            // 若发送失败则连接已断开，break 出循环
            _ = heartbeat.tick() => {
                if ws.send(Message::Ping(axum::body::Bytes::new())).await.is_err() {
                    tracing::warn!("WS heartbeat failed — connection lost, closing");
                    break;
                }
            }

            // ── 接收 ColdPath 结果（排队按轮次输出） ──
            Some((cold_turn, candidates)) = cold_rx.recv() => {
                // 按轮次存入缓冲区
                pending_candidates.insert(cold_turn, candidates);
                // 容量保护：超过 50 个未输出轮次时，跳过最旧的空洞
                const MAX_PENDING: usize = 50;
                if pending_candidates.len() > MAX_PENDING {
                    // 找到最小的 key（最旧的未完成 turn），跳过它
                    if let Some(&oldest) = pending_candidates.keys().next() {
                        if oldest > next_turn_to_show {
                            tracing::warn!(
                                "ColdPath backlog: {} pending turns, skipping turn {} (stuck)",
                                pending_candidates.len(), next_turn_to_show
                            );
                            next_turn_to_show = oldest;
                        }
                    }
                }
                // 从最早未输出的轮次开始，连续输出
                while let Some(ready) = pending_candidates.remove(&next_turn_to_show) {
                    if !ready.is_empty()
                        && ws.send(Message::Text(json!({
                            "type": "candidates",
                            "candidates": ready,
                        }).to_string().into())).await.is_err() {
                            tracing::warn!("WS send(candidates) failed — connection lost");
                            break;
                        }
                    next_turn_to_show += 1;
                }
            }

            // ❄️ ColdPath 2 通知：CP2 更新 plan 后通知前端刷新
            Some(true) = cp2_rx.recv() => {
                if ws.send(Message::Text(json!({
                    "type": "plan_updated",
                }).to_string().into())).await.is_err() {
                    tracing::warn!("WS send(plan_updated from CP2) failed — connection lost");
                }
            }
        }
    }

    // ── 调试日志：session_end ──
    if let Some(logger) = debug_logger {
        match logger.close().await {
            Ok(summary) => {
                tracing::info!(
                    "Debug log closed: conv={}, entries={}, size={}",
                    summary.conversation_id, summary.entry_count, summary.file_size_bytes,
                );
                // 写入 debug_logs DB 表（供管理后台查询）
                let log_path = format!("data/debug_logs/{}/{}.jsonl",
                    summary.date, summary.conversation_id);
                if let Err(e) = crate::db_pool::get_conn().execute(
                    "UPDATE debug_logs SET entry_count = ?1, file_size_bytes = ?2, log_file_path = ?3 WHERE id = ?4",
                    rusqlite::params![
                        summary.entry_count as i64,
                        summary.file_size_bytes as i64,
                        log_path,
                        summary.conversation_id,
                    ],
                ) {
                    tracing::warn!("Failed to update debug_logs record: {}", e);
                }
            }
            Err(e) => tracing::warn!("Debug log close failed: {}", e),
        }
    }

    // Phase 2: 会话结束成就检测
    if !last_user_id.is_empty() {
        let conn = crate::db_pool::get_conn();
        crate::achievement_engine::publish(&conn, crate::achievement_engine::AppEvent::ConversationEnded { user_id: last_user_id });
    }
}

