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

                // 检查订阅状态
                {
                    let conn = crate::db_pool::get_conn();
                    let expires: Option<String> = conn.query_row(
                        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
                        rusqlite::params![chat_req.user_id],
                        |row| row.get(0),
                    ).ok().flatten();
                    let now = chrono::Utc::now().format("%Y-%m-%d").to_string();
                    let expired = match &expires {
                        Some(e) => e.as_str() < now.as_str(),
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

                // ── 学习计划上下文注入 ──
                {
                    let conn = crate::db_pool::get_conn();
                    let mut stmt = conn.prepare(
                        "SELECT mode, goal, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1"
                    ).ok();
                    if let Some(ref mut stmt) = stmt {
                        if let Ok(row) = stmt.query_row(rusqlite::params![chat_req.conversation_id], |row| {
                            Ok((row.get::<_, Option<String>>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
                        }) {
                            if let (Some(mode), Ok(plan)) = (&row.0, serde_json::from_str::<serde_json::Value>(&row.2)) {
                                if mode == "structured" {
                                    let goal = &row.1;
                                    prompt.push_str(&format!("\n\n### 学习计划"));
                                    prompt.push_str(&format!("\n长期目标: {}", goal));
                                    if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                                        for stage in stages {
                                            let name = stage["name"].as_str().unwrap_or("");
                                            let status = stage["status"].as_str().unwrap_or("pending");
                                            if status == "in_progress" || status == "pending" {
                                                prompt.push_str(&format!("\n当前阶段: {} ({})", name, status));
                                                if let Some(tasks) = stage["tasks"].as_array() {
                                                    for task in tasks {
                                                        let tname = task["name"].as_str().unwrap_or("");
                                                        let tstatus = task["status"].as_str().unwrap_or("pending");
                                                        prompt.push_str(&format!("\n  - {}: {}", tname, tstatus));
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

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

                // ── 解析学习计划更新（先于 DB 保存和 done 发送） ──
                let mut plan_updated = false;
                // 用 <plan_update 匹配（可能被截断）
                if let Some(start) = final_reply.find("<plan_update") {
                    if let Some(tag_end) = final_reply[start..].find('>') {
                        // 找到了完整的 <plan_update> 标签
                        let block_start = start + tag_end + 1;
                        if let Some(end) = final_reply[block_start..].find("</plan_update>") {
                            // 完整的 <plan_update>...</plan_update>
                            let json_str = final_reply[block_start..block_start + end].to_string();
                            final_reply.replace_range(start..block_start + end + 14, "");
                            if let Ok(update) = serde_json::from_str::<serde_json::Value>(&json_str) {
                                let conn = crate::db_pool::get_conn();
                                let is_new = update.get("is_new_plan").and_then(|v| v.as_bool()).unwrap_or(false);
                                if is_new {
                                    // 检查是否已有学习计划（防止重复创建）
                                    let existing_plan: Option<String> = conn.query_row(
                                        "SELECT id FROM learning_plans WHERE conversation_id = ?1 AND mode != 'deleted' LIMIT 1",
                                        rusqlite::params![chat_req.conversation_id],
                                        |row| row.get(0)
                                    ).ok();

                                    let now = chrono::Utc::now().to_rfc3339();
                                    let goal = update["goal"].as_str().unwrap_or("");
                                    let mut plan = update.clone();
                                    let _ = plan.as_object_mut().map(|o| { o.remove("is_new_plan"); o.remove("goal"); });

                                    if let Some(existing_id) = existing_plan {
                                        // 已有计划，更新而非新建
                                        let _ = conn.execute(
                                            "UPDATE learning_plans SET goal=?1, plan_json=?2, updated_at=?3 WHERE id=?4",
                                            rusqlite::params![goal, plan.to_string(), now, existing_id],
                                        );
                                    } else {
                                        // 无已有计划，创建新计划
                                        let id = uuid::Uuid::new_v4().to_string();
                                        let _ = conn.execute(
                                            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?7)",
                                            rusqlite::params![id, chat_req.user_id, chat_req.conversation_id, goal, "", plan.to_string(), now],
                                        );
                                    }
                                    final_reply = render_plan(&update);
                                    plan_updated = true;
                                } else {
                                    let plan_row: Option<(String, String)> = conn.query_row(
                                        "SELECT id, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
                                        rusqlite::params![chat_req.conversation_id],
                                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                                    ).ok();
                                    if let Some((plan_id, plan_str)) = plan_row {
                                        if let Ok(mut plan) = serde_json::from_str::<serde_json::Value>(&plan_str) {
                                            if let Some(concepts) = update.get("completed_concepts").and_then(|c| c.as_array()) {
                                                let existing = plan.get("completed_concepts").and_then(|c| c.as_array().map(|a| a.clone())).unwrap_or_default();
                                                let mut all = existing.clone();
                                                for c in concepts { if !all.iter().any(|x| x == c) { all.push(c.clone()); } }
                                                plan["completed_concepts"] = serde_json::json!(all);
                                            }
                                            if update.get("current_task_complete").and_then(|c| c.as_bool()).unwrap_or(false) {
                                                if let Some(stages) = plan["stages"].as_array_mut() {
                                                    for stage in stages.iter_mut() {
                                                        if stage["status"] == "in_progress" || stage["status"] == "pending" {
                                                            if let Some(tasks) = stage["tasks"].as_array_mut() {
                                                                for task in tasks.iter_mut() {
                                                                    if task["status"] == "in_progress" {
                                                                        task["status"] = serde_json::json!("done");
                                                                        if tasks.iter().all(|t| t["status"] == "done") {
                                                                            stage["status"] = serde_json::json!("done");
                                                                            if let Some(next) = update.get("next_stage_suggestion").and_then(|v| v.as_str()) {
                                                                                for s in stages.iter_mut() {
                                                                                    if s["status"] == "pending" && s["name"] == next {
                                                                                        s["status"] = serde_json::json!("in_progress");
                                                                                        if let Some(next_tasks) = s["tasks"].as_array_mut() {
                                                                                            if let Some(first) = next_tasks.first_mut() {
                                                                                                first["status"] = serde_json::json!("in_progress");
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                        break;
                                                                    }
                                                                }
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            let now = chrono::Utc::now().to_rfc3339();
                                            let _ = conn.execute(
                                                "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE id = ?3",
                                                rusqlite::params![plan.to_string(), now, plan_id],
                                            );
                                            plan_updated = true;
                                            // ── 成就检测 ──
                                            // 检查刚完成的任务 → bronze
                                            if let Some(assessment) = update.get("assessment") {
                                                if assessment.get("passed").and_then(|v| v.as_bool()).unwrap_or(false) {
                                                    if let Some(task_name) = assessment.get("task").and_then(|v| v.as_str()) {
                                                        write_achievement(&conn, &chat_req.user_id,
                                                            &format!("{}_bronze", task_name),
                                                            &format!("{}入门", task_name), "🥉", "bronze", "task");
                                                    }
                                                }
                                            }
                                            // 检查 stage done → silver
                                            if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                                                for stage in stages {
                                                    if stage["status"] == "done" {
                                                        let stage_name = stage["name"].as_str().unwrap_or("阶段");
                                                        let key = format!("{}_silver", stage_name);
                                                        // 检查是否已有该成就
                                                        let exists: bool = conn.query_row(
                                                            "SELECT 1 FROM achievements WHERE user_id = ?1 AND achievement_key = ?2",
                                                            rusqlite::params![chat_req.user_id, key],
                                                            |_| Ok(true)
                                                        ).unwrap_or(false);
                                                        if !exists {
                                                            write_achievement(&conn, &chat_req.user_id,
                                                                &key, &format!("{}精英", stage_name), "🥈", "silver", "stage");
                                                        }
                                                        // 检查 domain done → gold
                                                        if stages.iter().all(|s| s["status"] == "done") {
                                                            let domain_name = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("领域");
                                                            let dkey = format!("{}_gold", domain_name);
                                                            let dexists: bool = conn.query_row(
                                                                "SELECT 1 FROM achievements WHERE user_id = ?1 AND achievement_key = ?2",
                                                                rusqlite::params![chat_req.user_id, dkey],
                                                                |_| Ok(true)
                                                            ).unwrap_or(false);
                                                            if !dexists {
                                                                write_achievement(&conn, &chat_req.user_id,
                                                                    &dkey, &format!("{}大师", domain_name), "🥇", "gold", "domain");
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // 找到了 <plan_update> 但找不到 </plan_update>（截断），删掉
                            final_reply.truncate(start);
                        }
                    } else {
                        // 找到了 <plan_update 但找不到 >（严重截断），删掉
                        final_reply.truncate(start);
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

/// 从 plan_update JSON 渲染学习计划文本
fn render_plan(plan: &serde_json::Value) -> String {
    let goal = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("学习计划");
    let empty_vec: Vec<serde_json::Value> = vec![];
    let stages = plan.get("stages").and_then(|v| v.as_array()).unwrap_or(&empty_vec);

    let mut out = format!("好的！我来为你制定一个学习计划 📋\n\n**目标：{}**\n", goal);

    for (_si, stage) in stages.iter().enumerate() {
        let name = stage["name"].as_str().unwrap_or("");
        let status = stage["status"].as_str().unwrap_or("pending");
        let icon = if status == "in_progress" { "🔄" } else if status == "done" { "✅" } else { "📌" };
        out.push_str(&format!("\n### {} {} \n", icon, name));

        if let Some(tasks) = stage["tasks"].as_array() {
            for (_ti, task) in tasks.iter().enumerate() {
                let tname = task["name"].as_str().unwrap_or("");
                let tstatus = task["status"].as_str().unwrap_or("pending");
                let desc = task.get("description").and_then(|v| v.as_str()).unwrap_or("");
                let tick = if tstatus == "done" { "✅" } else if tstatus == "in_progress" { "🔄" } else { "  " };
                out.push_str(&format!("\n- {} **{}**", tick, tname));
                if !desc.is_empty() {
                    out.push_str(&format!("\n  {}", desc));
                }
            }
        }
    }

    let first_task = stages.iter()
        .find(|s| s["status"] == "in_progress")
        .and_then(|s| s["tasks"].as_array())
        .and_then(|t| t.iter().find(|t| t["status"] == "in_progress"))
        .and_then(|t| t["name"].as_str());

    if let Some(task_name) = first_task {
        out.push_str(&format!("\n\n你想先从 **{}** 开始吗？😊", task_name));
    } else {
        out.push_str("\n\n准备好开始了吗？😊");
    }

    out
}

/// 写入成就（去重）
fn write_achievement(conn: &rusqlite::Connection, user_id: &str, key: &str, name: &str, icon: &str, tier: &str, source: &str) {
    let exists: bool = conn.query_row(
        "SELECT 1 FROM achievements WHERE user_id = ?1 AND achievement_key = ?2",
        rusqlite::params![user_id, key],
        |_| Ok(true)
    ).unwrap_or(false);
    if !exists {
        let now = chrono::Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO achievements (id, user_id, achievement_key, name, icon, tier, source, unlocked_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), user_id, key, name, icon, tier, source, now],
        );
    }
}
