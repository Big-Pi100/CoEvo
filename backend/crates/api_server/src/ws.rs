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

pub async fn handle_ws(mut ws: WebSocket) {
    // ColdPath 结果通道：后台 task 提取完概念后通过此通道发回
    let (cold_tx, mut cold_rx) = mpsc::channel::<(u32, Vec<serde_json::Value>)>(8);
    let mut turn_counter: u32 = 0;
    let mut next_turn_to_show: u32 = 0;
    let mut pending_candidates: std::collections::BTreeMap<u32, Vec<serde_json::Value>> = std::collections::BTreeMap::new();
    let mut token_verified = false;
    let mut kick_notify: Option<Arc<tokio::sync::Notify>> = None;

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

                let raw_req: RawChatRequest = match serde_json::from_str(&text) {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = ws.send(Message::Text(
                            json!({"type":"error","content": format!("Invalid request: {}", e)}).to_string().into()
                        )).await;
                        continue;
                    }
                };

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
                        let _ = ws.send(Message::Text(
                            json!({"type":"error","content": msg}).to_string().into()
                        )).await;
                        continue;
                    }
                }

                // 保存用户消息
                let now_str = chrono::Utc::now().to_rfc3339();
                {
                    let conn = crate::db_pool::get_conn();
                    let _ = conn.execute(
                        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
                        rusqlite::params![chat_req.conversation_id, chat_req.user_id, now_str],
                    );
                    let _ = conn.execute(
                        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'user', ?3, ?4)",
                        rusqlite::params![uuid::Uuid::new_v4().to_string(), chat_req.conversation_id, chat_req.message, now_str],
                    );
                }

                let llm_config = crate::llm::get_config();
                let (tx, mut rx) = mpsc::channel::<LlmEvent>(256);

                // 加载最近 10 轮对话历史作为上下文
                let history = {
                    let conn = crate::db_pool::get_conn();
                    let mut stmt = conn.prepare(
                        "SELECT role, content FROM conversation_turns
                         WHERE conversation_id = ?1
                         ORDER BY created_at DESC LIMIT 10"
                    ).unwrap();
                    // 反转: 从旧到新
                    let mut turns: Vec<(String, String)> = stmt.query_map(
                        rusqlite::params![chat_req.conversation_id],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                    ).unwrap().filter_map(|r| r.ok()).collect();
                    turns.reverse();
                    turns
                };

                // ── 查询学习计划，判定生命周期状态 ──
                let (system_prompt, plan_context) = {
                    let conn = crate::db_pool::get_conn();
                    let (mode, ctx) = crate::plan_handler::build_plan_context(&conn, &chat_req.conversation_id);
                    let templates = chat_engine::prompt_loader::get();
                    let sp = if mode == "structured" {
                        templates.chat_system_structured.clone()
                    } else {
                        templates.chat_system_free.clone()
                    };
                    (sp, ctx)
                };

                // ── 构建 user_content（对话历史 + 计划上下文 + 当前消息） ──
                let mut user_content = String::new();
                if history.len() > 1 {
                    let context = &history[..history.len() - 1];
                    // 滑动窗口: 保留最近 N 轮, 总长度 ≤5000 字, 不截断单条
                    let mut lines: Vec<String> = Vec::new();
                    let mut total = 0usize;
                    for (role, content) in context.iter().rev() {
                        let label = if role == "user" { "用户" } else { "AI" };
                        let line = format!("\n{}: {}", label, content);
                        let next = total + line.len();
                        if next > 5000 { break; }
                        total = next;
                        lines.push(line);
                    }
                    if !lines.is_empty() {
                        lines.reverse();
                        user_content.push_str("\n\n### 对话历史");
                        for l in &lines { user_content.push_str(l); }
                    }
                }
                if !plan_context.is_empty() {
                    user_content.push_str(&plan_context);
                }
                user_content.push_str(&format!("\n\n### 当前对话\n用户: {}", chat_req.message));

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
                loop {
                    match tokio::time::timeout(Duration::from_secs(60), rx.recv()).await {
                        Ok(Some(LlmEvent::Thinking)) => {
                            let _ = ws.send(Message::Text(json!({"type":"thinking"}).to_string().into())).await;
                        }
                        Ok(Some(LlmEvent::Token(content))) => {
                            final_reply.push_str(&content);
                            if is_planning {
                                // 计划生成中，不再转发原始 token
                            } else if final_reply.contains("<plan_update") {
                                is_planning = true;
                                let _ = ws.send(Message::Text(json!({
                                    "type":"planning"
                                }).to_string().into())).await;
                            } else {
                                let _ = ws.send(Message::Text(json!({"type":"token","content":content}).to_string().into())).await;
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
                if !got_done && final_reply.is_empty() {
                    final_reply = "[LLM 响应超时]".to_string();
                }

                // ── 解析学习计划更新（共用 plan_handler 模块） ──
                let mut plan_updated;
                {
                    let conn = crate::db_pool::get_conn();
                    let result = crate::plan_handler::handle_plan_update(
                        &conn, &final_reply, &chat_req.conversation_id, &chat_req.user_id,
                    );
                    final_reply = result.cleaned_reply;
                    plan_updated = result.plan_updated;

                    if result.is_new_plan {
                        if let Some(ref plan) = result.plan_json {
                            final_reply = crate::plan_handler::render_plan(plan);
                        }
                    }

                    // ── 成就检测（仅非新建计划的更新） ──
                    if result.plan_updated && !result.is_new_plan {
                        if let Some(ref plan) = result.plan_json {
                            if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                                for stage in stages {
                                    if stage["status"] == "done" {
                                        let stage_name = stage["name"].as_str().unwrap_or("阶段");
                                        let key = format!("{}_silver", stage_name);
                                        if !crate::plan_handler::achievement_exists(&conn, &chat_req.user_id, &key) {
                                            crate::plan_handler::write_achievement(&conn, &chat_req.user_id,
                                                &key, &format!("{}精英", stage_name), "🥈", "silver", "stage");
                                        }
                                        // 检查 domain done → gold
                                        if stages.iter().all(|s| s["status"] == "done") {
                                            let domain_name = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("领域");
                                            let dkey = format!("{}_gold", domain_name);
                                            if !crate::plan_handler::achievement_exists(&conn, &chat_req.user_id, &dkey) {
                                                crate::plan_handler::write_achievement(&conn, &chat_req.user_id,
                                                    &dkey, &format!("{}大师", domain_name), "🥇", "gold", "domain");
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 保存 assistant 回复（final_reply 已清理/渲染）
                let now_str = chrono::Utc::now().to_rfc3339();
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

                // ⚡ HotPath: 发 done
                let _ = ws.send(Message::Text(json!({
                    "type": "done",
                    "reply": final_reply,
                }).to_string().into())).await;

                // ── 代码层兜底：若 LLM 未处理回退请求，自动回退 ──
                if !plan_updated && crate::plan_handler::check_revert_signals(&chat_req.message) {
                    if let Some(_plan) = {
                        let conn = crate::db_pool::get_conn();
                        crate::plan_handler::auto_revert(&conn, &chat_req.conversation_id)
                    } {
                        plan_updated = true;
                        tracing::info!("Auto-revert triggered by user message: {}", &chat_req.message[..chat_req.message.len().min(80)]);
                    }
                }

                // 通知前端刷新计划
                if plan_updated {
                    let _ = ws.send(Message::Text(json!({
                        "type": "plan_updated",
                    }).to_string().into())).await;
                }

                let current_turn = turn_counter;
                turn_counter += 1;

                // ❄️ ColdPath: 扔到后台 task，不阻塞消息接收
                let user_id = chat_req.user_id.clone();
                let msg = chat_req.message.clone();
                let config = llm_config.clone();
                let cold_tx = cold_tx.clone();
                let cold_turn = current_turn;
                let history_clone = history.clone();
                tokio::spawn(async move {
                    // Bug 1 修复：确保任何 DB 错误路径都向 cold_tx 发送空结果，
                    // 避免 BTreeMap 产生空洞导致后续 candidates 永久阻塞。
                    // 注意：rusqlite Connection/Statement 不是 Send，
                    // DB 操作必须在独立 block 内完成并 drop conn 后才能 .await。

                    let result: Option<(Vec<String>, Vec<String>)> = 'db: {
                        let conn = crate::db_pool::get_conn();

                        let ef: Vec<String> = {
                            let mut stmt = match conn.prepare(
                                "SELECT LOWER(front) FROM cards WHERE user_id = ?1"
                            ) {
                                Ok(s) => s,
                                Err(_) => break 'db None,
                            };
                            let rows = match stmt.query_map(
                                rusqlite::params![user_id],
                                |row| row.get::<_, String>(0)
                            ) {
                                Ok(r) => r,
                                Err(_) => break 'db None,
                            };
                            rows.filter_map(|r| r.ok()).collect()
                        };

                        let sf: Vec<String> = {
                            let mut stmt = match conn.prepare(
                                "SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1"
                            ) {
                                Ok(s) => s,
                                Err(_) => break 'db None,
                            };
                            let rows = match stmt.query_map(
                                rusqlite::params![user_id],
                                |row| row.get::<_, String>(0)
                            ) {
                                Ok(r) => r,
                                Err(_) => break 'db None,
                            };
                            rows.filter_map(|r| r.ok()).collect()
                        };

                        Some((ef, sf))
                    }; // conn dropped here — safe to .await now

                    let (existing_fronts, skipped_fronts) = match result {
                        Some(v) => v,
                        None => {
                            let _ = cold_tx.send((cold_turn, vec![])).await;
                            return;
                        }
                    };

                    // 30 秒超时：防止 LLM 挂起导致 turn 永远不到达
                    let extraction = match tokio::time::timeout(
                        Duration::from_secs(30),
                        chat_engine::concept_extractor::extract_concepts(
                            &user_id, &msg, &final_reply,
                            &existing_fronts, &skipped_fronts, &config,
                            &history_clone,
                        ),
                    ).await {
                        Ok(e) => e,
                        Err(_) => {
                            tracing::warn!("ColdPath concept extraction timed out for turn {}", cold_turn);
                            let _ = cold_tx.send((cold_turn, vec![])).await;
                            return;
                        }
                    };

                    let candidates: Vec<serde_json::Value> = extraction.candidates.iter().map(|c| {
                        json!({"front": c.front, "back": c.back, "source_sentence": c.source_sentence, "domain": c.domain})
                    }).collect();
                    let _ = cold_tx.send((cold_turn, candidates)).await;
                });
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
                    if !ready.is_empty() {
                        let _ = ws.send(Message::Text(json!({
                            "type": "candidates",
                            "candidates": ready,
                        }).to_string().into())).await;
                    }
                    next_turn_to_show += 1;
                }
            }
        }
    }
}

