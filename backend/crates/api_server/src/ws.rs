//! WebSocket Handler — 基于 select! 的消息与 ColdPath 并发处理
//!
//! ⚡ HotPath: 流式回复 → done 立即发送 → 不等概念提取
//! ❄️ ColdPath: 通过 channel 异步提取概念，不阻塞消息接收

use axum::extract::ws::{Message, WebSocket};
use chat_engine::llm_caller::{LlmCaller, LlmEvent};
use serde_json::json;
use tokio::sync::mpsc;
use std::time::Duration;

pub async fn handle_ws(mut ws: WebSocket) {
    // ColdPath 结果通道：后台 task 提取完概念后通过此通道发回
    let (cold_tx, mut cold_rx) = mpsc::channel::<(u32, Vec<serde_json::Value>)>(8);
    let mut turn_counter: u32 = 0;
    let mut next_turn_to_show: u32 = 0;
    let mut pending_candidates: std::collections::BTreeMap<u32, Vec<serde_json::Value>> = std::collections::BTreeMap::new();

    loop {
        tokio::select! {
            // ── 接收用户消息（HotPath） ──
            msg = ws.recv() => {
                let text = match msg {
                    Some(Ok(Message::Text(t))) => t,
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => continue,
                };

                let chat_req: shared_types::conversation::ChatRequest = match serde_json::from_str(&text) {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = ws.send(Message::Text(
                            json!({"type":"error","content": format!("Invalid request: {}", e)}).to_string().into()
                        )).await;
                        continue;
                    }
                };

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

                // 构建带上下文的 prompt
                let mut prompt = chat_engine::prompt_loader::get().chat_system.clone();
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
                        prompt.push_str("\n\n### 对话历史");
                        for l in &lines { prompt.push_str(l); }
                    }
                }
                prompt.push_str(&format!("\n\n### 当前对话\n用户: {}", chat_req.message));

                // 后台流式生成 LLM 回复
                let cfg = llm_config.clone();
                let tx2 = tx.clone();
                tokio::spawn(async move {
                    let mut caller = LlmCaller::new(cfg);
                    if let Err(e) = caller.stream_generate(&prompt, tx2).await {
                        let _ = tx.send(LlmEvent::Done(format!("[LLM 暂时不可用: {}]", e))).await;
                    }
                });

                // ⚡ HotPath: 等待 LLM 回复，流式转发
                let mut final_reply = String::new();
                let mut got_done = false;
                loop {
                    match tokio::time::timeout(Duration::from_secs(60), rx.recv()).await {
                        Ok(Some(LlmEvent::Thinking)) => {
                            let _ = ws.send(Message::Text(json!({"type":"thinking"}).to_string().into())).await;
                        }
                        Ok(Some(LlmEvent::Token(content))) => {
                            final_reply.push_str(&content);
                            let _ = ws.send(Message::Text(json!({"type":"token","content":content}).to_string().into())).await;
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

                // 保存 assistant 回复
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

                // ⚡ HotPath: 先发 done
                let _ = ws.send(Message::Text(json!({
                    "type": "done",
                    "reply": final_reply,
                }).to_string().into())).await;

                let current_turn = turn_counter;
                turn_counter += 1;

                // ❄️ ColdPath: 扔到后台 task，不阻塞消息接收
                let user_id = chat_req.user_id.clone();
                let msg = chat_req.message.clone();
                let config = llm_config.clone();
                let cold_tx = cold_tx.clone();
                let cold_turn = current_turn;
                tokio::spawn(async move {
                    let (existing_fronts, skipped_fronts) = {
                        let conn = crate::db_pool::get_conn();
                        let ef: Vec<String> = {
                            let mut stmt = match conn.prepare("SELECT LOWER(front) FROM cards WHERE user_id = ?1") {
                                Ok(s) => s,
                                Err(_) => return,
                            };
                            let rows = match stmt.query_map(rusqlite::params![user_id], |row| row.get::<_, String>(0)) {
                                Ok(r) => r,
                                Err(_) => return,
                            };
                            rows.filter_map(|r| r.ok()).collect()
                        };
                        let sf: Vec<String> = {
                            let mut stmt = match conn.prepare("SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1") {
                                Ok(s) => s,
                                Err(_) => return,
                            };
                            let rows = match stmt.query_map(rusqlite::params![user_id], |row| row.get::<_, String>(0)) {
                                Ok(r) => r,
                                Err(_) => return,
                            };
                            rows.filter_map(|r| r.ok()).collect()
                        };
                        (ef, sf)
                    };

                    let extraction = chat_engine::concept_extractor::extract_concepts(
                        &user_id, &msg, &final_reply,
                        &existing_fronts, &skipped_fronts, &config,
                    ).await;

                    let candidates: Vec<serde_json::Value> = extraction.candidates.iter().map(|c| {
                        json!({"front": c.front, "back": c.back, "source_sentence": c.source_sentence, "domain": c.domain})
                    }).collect();
                    let _ = cold_tx.send((cold_turn, candidates)).await;
                });
            }

            // ── 接收 ColdPath 结果（排队按轮次输出） ──
            Some((cold_turn, candidates)) = cold_rx.recv() => {
                // 按轮次存入缓冲区
                pending_candidates.insert(cold_turn, candidates);
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
