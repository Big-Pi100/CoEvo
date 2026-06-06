//! 学习计划处理 — WebSocket 和 REST 共用模块
//!
//! 负责:
//!   1. 解析 LLM 回复中的 <plan_update>...</plan_update> XML 标签
//!   2. 创建/更新 conversation_plans + user_plan_progress
//!   3. 返回清理后的回复文本

use serde_json::json;
use std::collections::HashMap;
use std::sync::Mutex;

// ── LLM Context 日志缓冲区（供测试/诊断使用）──
static CONTEXT_LOG: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// 启用 context 日志（测试用）。清空历史缓冲区。
pub fn enable_context_log() {
    *CONTEXT_LOG.lock().unwrap() = Vec::new();
}

/// 读取并清空 context 日志缓冲区。
/// 返回自上次调用以来所有新产生的 context 文本。
pub fn drain_context_log() -> Vec<String> {
    let mut log = CONTEXT_LOG.lock().unwrap();
    let result = log.clone();
    log.clear();
    result
}

// ── 完整 LLM 输入日志（system_prompt + user_content，由 routes/ws 写入）──
static LLM_INPUT_LOG: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// 记录一次 LLM 调用输入（由 routes.rs / ws.rs 调用）
pub fn log_llm_input(system_prompt: &str, user_content: &str) {
    if let Ok(mut log) = LLM_INPUT_LOG.lock() {
        log.push((system_prompt.to_string(), user_content.to_string()));
    }
}

/// 读取并清空 LLM 输入日志
pub fn drain_llm_input_log() -> Vec<(String, String)> {
    let mut log = LLM_INPUT_LOG.lock().unwrap();
    let result = log.clone();
    log.clear();
    result
}

/// ── Prompt 来源日志（domain + mode，由 ws.rs 写入，供 e2e 测试验证）──
static PROMPT_SOURCE_LOG: Mutex<Vec<String>> = Mutex::new(Vec::new());

pub fn log_prompt_source(source: &str) {
    if let Ok(mut log) = PROMPT_SOURCE_LOG.lock() {
        log.push(source.to_string());
    }
}

pub fn drain_prompt_source_log() -> Vec<String> {
    let mut log = PROMPT_SOURCE_LOG.lock().unwrap();
    let result = log.clone();
    log.clear();
    result
}

/// 从 task_status 中找到当前 in_progress 的 task 名称
pub fn get_current_task_name(task_status: &serde_json::Value) -> Option<String> {
    let stages = task_status.get("stages").and_then(|v| v.as_array())?;
    for stage in stages {
        let tasks = stage.get("tasks").and_then(|v| v.as_array())?;
        for task in tasks {
            let status = task.get("status").and_then(|v| v.as_str()).unwrap_or("pending");
            if status == "in_progress" {
                return task.get("name").and_then(|v| v.as_str()).map(|s| s.to_string());
            }
        }
    }
    // 没有 in_progress → 找第一个 pending
    for stage in stages {
        let tasks = stage.get("tasks").and_then(|v| v.as_array())?;
        if let Some(task) = tasks.first() {
            return task.get("name").and_then(|v| v.as_str()).map(|s| s.to_string());
        }
    }
    None
}

/// plan_update 处理结果
pub struct PlanUpdateResult {
    /// 清理后的回复文本（去除 plan_update 标签）
    pub cleaned_reply: String,
    /// 是否为新建计划
    pub is_new_plan: bool,
    /// 计划是否被更新
    pub plan_updated: bool,
    /// 解析出的 plan_update JSON（用于后续渲染计划文本）
    pub task_status: Option<serde_json::Value>,
}

/// 解析并处理 LLM 回复中的 <plan_update> 标签
///
/// 返回清理后的文本 + 处理结果。调用方负责：
/// - 渲染计划文本（render_plan）
/// - 发送 WebSocket 通知
pub fn handle_plan_update(
    conn: &rusqlite::Connection,
    raw_reply: &str,
    conversation_id: &str,
    user_id: &str,
) -> PlanUpdateResult {
    eprintln!("[MARK] handle_plan_update ENTER");
    let mut final_reply = raw_reply.to_string();
    let mut plan_updated = false;
    let mut is_new_plan = false;
    let mut task_status: Option<serde_json::Value> = None;

    // 用 <plan_update 或 <reading_update 匹配（可能被截断）
    if let Some(start) = final_reply.find("<plan_update") {
        if let Some(tag_end) = final_reply[start..].find('>') {
            let block_start = start + tag_end + 1;
            if let Some(end) = final_reply[block_start..].find("</plan_update>") {
                // 完整的 <plan_update>...</plan_update>
                let json_str = final_reply[block_start..block_start + end].to_string();
                final_reply.replace_range(start..block_start + end + 14, "");

                // 尝试解析 JSON（支持 LLM 常见格式错误修复）
                let update = match serde_json::from_str::<serde_json::Value>(&json_str) {
                    Ok(v) => Some(v),
                    Err(e) => {
                        // 修复常见 LLM JSON 错误：字符串值中未转义的反斜杠
                        // LLM 可能在 description 等字段中输出 \d、\w、\n 字面量
                        // JSON 规范要求反斜杠必须转义为 \\，否则解析失败
                        let repaired = repair_json_backslashes(&json_str);
                        match serde_json::from_str::<serde_json::Value>(&repaired) {
                            Ok(v) => {
                                tracing::warn!(
                                    "Plan JSON repaired (unescaped backslashes). Original error: {}",
                                    e
                                );
                                Some(v)
                            }
                            Err(e2) => {
                                tracing::error!(
                                    "Plan JSON parse failed after repair. Original: {}. Repaired: {}. JSON (first 300): {}...",
                                    e, e2, &json_str[..json_str.len().min(300)]
                                );
                                None
                            }
                        }
                    }
                };

                if let Some(update) = update {
                    is_new_plan = update.get("is_new_plan")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);

                    if is_new_plan {
                        task_status = Some(update.clone());
                        upsert_learning_plan(conn, user_id, conversation_id, &update);
                        plan_updated = true;
                    } else if let Some(plan) = apply_plan_mutations(conn, conversation_id, &update) {
                        task_status = Some(plan.clone());
                        plan_updated = true;
                    }

                    // 统一更新 user_plan_progress：按 task_key 只更新变化的行，不重置全部
                    if plan_updated {
                        if let Some(merged) = task_status.as_ref() {
                            if let Some(stages) = merged.get("stages").and_then(|s| s.as_array()) {
                                let now_ts = chrono::Utc::now().timestamp();
                                for stage in stages {
                                    if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                                        for task in tasks {
                                            let task_key = task.get("task_key").and_then(|k| k.as_str())
                                                .or_else(|| task.get("name").and_then(|n| n.as_str()))
                                                .unwrap_or("");
                                            let status = task.get("status").and_then(|s| s.as_str())
                                                .unwrap_or("pending");
                                            if !task_key.is_empty() {
                                                let affected = conn.execute(
                                                    "UPDATE user_plan_progress SET status = ?1, updated_at = ?2 WHERE plan_id IN (SELECT id FROM conversation_plans WHERE conversation_id = ?3) AND task_key = ?4",
                                                    rusqlite::params![status, now_ts, conversation_id, task_key],
                                                ).unwrap_or(0);
                                                if affected == 0 {
                                                    // 可能该行还不存在（第一次），INSERT
                                                    let progress_id = uuid::Uuid::new_v4().to_string();
                                                    conn.execute(
                                                        "INSERT OR IGNORE INTO user_plan_progress (id, user_id, plan_id, task_key, status, updated_at)
                                                         VALUES (?1, (SELECT user_id FROM conversation_plans WHERE conversation_id = ?2), (SELECT id FROM conversation_plans WHERE conversation_id = ?3), ?4, ?5, ?6)",
                                                        rusqlite::params![progress_id, conversation_id, conversation_id, task_key, status, now_ts],
                                                    ).ok();
                                                    eprintln!("[CP2 SYNC] INSERTED: task_key='{}' status='{}'", task_key, status);
                                                } else {
                                                    eprintln!("[CP2 SYNC] OK: task_key='{}' → status='{}' ({} rows)", task_key, status, affected);
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

    // Phase 2: 计划完成成就检测
    if plan_updated && !is_new_plan {
        crate::achievement_engine::publish(conn, crate::achievement_engine::AppEvent::PlanCompleted { user_id: user_id.to_string() });
    }

    PlanUpdateResult {
        cleaned_reply: final_reply,
        is_new_plan,
        plan_updated,
        task_status,
    }
}

/// 创建或更新学习计划（新建模式）
fn upsert_learning_plan(
    conn: &rusqlite::Connection,
    user_id: &str,
    conversation_id: &str,
    update: &serde_json::Value,
) {
    let now = chrono::Utc::now().timestamp();
    let goal = update["goal"].as_str().unwrap_or("");
    let mut plan = update.clone();
    // 跟踪 plan_update 次数（用于评估和分析）
    let prev_count = plan.get("plan_update_count").and_then(|v| v.as_u64()).unwrap_or(0);
    if let Some(o) = plan.as_object_mut() { o.insert("plan_update_count".to_string(), serde_json::Value::Number((prev_count + 1).into())); }
    let _ = plan.as_object_mut().map(|o| {
        o.remove("is_new_plan");
        o.remove("goal");
    });

    // domain 不再等于 conversation_id，改为 ""（通用）
    // 无论什么模式，domain 在 DB 中只是分类标签，不由业务逻辑设置
    // 真正的学科路由信息从 plan_content JSON 的 pipeline_domain 字段读取
    // 详见 build_plan_context() (pipeline_router.rs)
    let domain = String::new();

    // 新格式：plan_content=完整结构，task_status=task_status 映射
    // 激活第一个未标记 in_progress 的任务（防止 reading 等模式全 pending）
    let has_in_progress = plan.get("stages").and_then(|s| s.as_array())
        .map(|stages| stages.iter().filter_map(|s| s["tasks"].as_array())
            .flat_map(|t| t.iter())
            .any(|t| t["status"].as_str() == Some("in_progress")))
        .unwrap_or(false);
    if !has_in_progress {
        // 找到第一个 task 设为 in_progress
        if let Some(stages) = plan.get_mut("stages").and_then(|s| s.as_array_mut()) {
            if let Some(first_stage) = stages.first_mut() {
                if let Some(tasks) = first_stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                    if let Some(first_task) = tasks.first_mut() {
                        first_task["status"] = serde_json::json!("in_progress");
                    }
                }
            }
        }
    }
    let task_status_val = extract_task_status(&plan);
    let task_status_str = serde_json::json!({"task_status": task_status_val}).to_string();
    let now_ts = chrono::Utc::now().timestamp();

    // ── 规范化 plan JSON：补充 sort 和 task_key ──
    // LLM 生成的计划通常没有 sort 和 task_key 字段
    // task_key 统一为 {stage:02d}-{task:02d} 格式
    if let Some(plan_obj) = plan.as_object_mut() {
        if let Some(stages) = plan_obj.get_mut("stages").and_then(|s| s.as_array_mut()) {
            for (s_idx, stage) in stages.iter_mut().enumerate() {
                if stage.get("sort").is_none() {
                    stage["sort"] = serde_json::json!(format!("{:02}", s_idx));
                }
                if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                    for (t_idx, task) in tasks.iter_mut().enumerate() {
                        // task 不需要 sort（顺序由数组位置隐式决定）
                        task.as_object_mut().map(|o| o.remove("sort"));
                        // task_key 统一为 digits 格式
                        let expected_key = format!("{:02}-{:02}", s_idx, t_idx);
                        task["task_key"] = serde_json::json!(expected_key);
                        // 确保每个 task 有 status（默认 pending）
                        if task.get("status").is_none() {
                            task["status"] = serde_json::json!("pending");
                        }
                    }
                }
                // 确保每个 stage 有 status（默认 pending）
                if stage.get("status").is_none() {
                    stage["status"] = serde_json::json!("pending");
                }
            }
        }
    }
    // 重新生成 plan_content_str（规范化后的 plan）
    let plan_content_str = plan.to_string();

        // ── V2.1: 同步写入 user_plan_progress ──
    // 将 plan 中的 tasks 写入 progress 行（只 INSERT 缺失行，已有行由 handle_plan_update 的 per-task UPDATE 更新状态）
    if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
        let is_conversation_plan = true;

        // 如果是对话计划且无已有记录，写入 conversation_plans
        if is_conversation_plan {
            let exists: bool = conn.query_row(
                "SELECT 1 FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                rusqlite::params![conversation_id],
                |_| Ok(()),
            ).is_ok();
            if !exists {
                let cp1_id = uuid::Uuid::new_v4().to_string();
                let _ = conn.execute(
                    "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, subject, grade_band, plan_content, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    rusqlite::params![cp1_id, user_id, conversation_id, goal, "", "", plan_content_str, now_ts, now_ts],
                );
            }
        }

        // 确定 plan_id（用于 user_plan_progress.plan_id）
        let progress_plan_id: String = if is_conversation_plan {
            conn.query_row(
                "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                rusqlite::params![conversation_id],
                |row| row.get(0),
            ).unwrap_or_default()
        } else {
            conn.query_row(
                "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                rusqlite::params![conversation_id],
                |row| row.get(0),
            ).unwrap_or_default()
        };

        // 只 INSERT 缺失的 progress 行（已有行不动，由 handle_plan_update 的 per-task UPDATE 更新状态）
        if !progress_plan_id.is_empty() {
            for (s_idx, stage) in stages.iter().enumerate() {
                if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                    for (t_idx, task) in tasks.iter().enumerate() {
                        let task_key = task.get("task_key").and_then(|k| k.as_str())
                            .unwrap_or("");
                        let task_name = task.get("name").and_then(|n| n.as_str())
                            .unwrap_or("");
                        let status = task.get("status").and_then(|s| s.as_str())
                            .unwrap_or("pending");
                        let final_key = if !task_key.is_empty() { task_key.to_string() }
                            else if !task_name.is_empty() { task_name.to_string() }
                            else { format!("s{}_t{}", s_idx, t_idx) };
                        let progress_id = uuid::Uuid::new_v4().to_string();
                        let _ = conn.execute(
                            "INSERT OR IGNORE INTO user_plan_progress (id, user_id, plan_id, task_key, status, updated_at)
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                            rusqlite::params![progress_id, user_id,
                                progress_plan_id, final_key, status, now_ts],
                        );
                    }
                }
            }
        }
    }
    eprintln!("[MARK] handle_plan_update EXIT");
}

/// 应用计划更新（非新建模式：completed_concepts, task_complete 等）
///
/// 返回更新后的完整 plan JSON，供调用方做成就检测
fn apply_plan_mutations(
    conn: &rusqlite::Connection,
    conversation_id: &str,
    update: &serde_json::Value,
) -> Option<serde_json::Value> {
    // 从 conversation_plans 读取（conversation_plans 是当前写入目标）
    let plan_row: Option<(String, String)> = conn.query_row(
        "SELECT id, plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
        )),
    ).ok();

    let (plan_id, plan_content_str) = match plan_row {
        Some(r) => r,
        None => {
            eprintln!("[CP2 MUTATE] no plan found in conversation_plans for conv={}", conversation_id);
            return None;
        }
    };

    let mut plan: serde_json::Value = match serde_json::from_str(&plan_content_str) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[CP2 MUTATE] JSON parse failed for conv={}: {}", conversation_id, e);
            return None;
        }
    };
    // plan_content 的 task 可能不含 status（status 在 user_plan_progress 中），需合并
    let progress_rows: Vec<(String, String)> = conn.prepare(
        "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
    ).ok().and_then(|mut stmt| {
        stmt.query_map(rusqlite::params![plan_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect())
    }).unwrap_or_default();
    let progress_map: HashMap<String, String> = progress_rows.into_iter().collect();
    if let Some(stages) = plan.get_mut("stages").and_then(|s| s.as_array_mut()) {
        for stage in stages.iter_mut() {
            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                let mut all_done = true;
                let mut has_in_progress = false;
                let mut has_pending = false;
                for task in tasks.iter_mut() {
                    let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                    let state = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                    task["status"] = serde_json::json!(state);
                    match state {
                        "done" | "skipped" => {},
                        "in_progress" => { has_in_progress = true; all_done = false; },
                        _ => { has_pending = true; all_done = false; },
                    }
                }
                stage["status"] = if all_done { json!("done") }
                    else if has_in_progress { json!("in_progress") }
                    else if has_pending { json!("pending") }
                    else { json!("done") };
            }
        }
    }

    // 更新 completed_concepts
    if let Some(concepts) = update.get("completed_concepts").and_then(|c| c.as_array()) {
        let existing = plan.get("completed_concepts")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default();
        let mut all = existing.clone();
        for c in concepts {
            if !all.iter().any(|x| x == c) {
                all.push(c.clone());
            }
        }
        plan["completed_concepts"] = json!(all);
    }

    // ── 子阶段进度更新 (task_sub_steps) ──
    if let Some(sub_steps) = update.get("task_sub_steps") {
        if let Some(stages) = plan["stages"].as_array_mut() {
            for stage in stages.iter_mut() {
                if stage["status"] == "in_progress" || stage["status"] == "pending" {
                    if let Some(tasks) = stage["tasks"].as_array_mut() {
                        for task in tasks.iter_mut() {
                            if task["status"] == "in_progress" {
                                let mut existing = task.get("sub_steps")
                                    .cloned()
                                    .unwrap_or(json!({"teach": "pending", "examples": "pending", "quiz": "pending"}));
                                if let Some(obj) = existing.as_object_mut() {
                                    if let Some(v) = sub_steps.get("teach").and_then(|s| s.as_str()) {
                                        obj.insert("teach".to_string(), json!(v));
                                    }
                                    if let Some(v) = sub_steps.get("examples").and_then(|s| s.as_str()) {
                                        obj.insert("examples".to_string(), json!(v));
                                    }
                                    if let Some(v) = sub_steps.get("quiz").and_then(|s| s.as_str()) {
                                        obj.insert("quiz".to_string(), json!(v));
                                    }
                                }
                                task["sub_steps"] = existing;
                                break;
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

    // 标记当前任务完成并推进下一任务
    // 检查两个位置：顶层（规范格式）和 assessment 内（LLM 常见格式漂移）
    let task_complete = update.get("current_task_complete")
        .and_then(|c| c.as_bool())
        .or_else(|| update.get("assessment").and_then(|a| a.get("current_task_complete")).and_then(|c| c.as_bool()))
        // 兼容 LLM 非标准输出：字符串或数组非空时视为完成
        .or_else(|| {
            let c = update.get("current_task_complete")?;
            if c.is_string() { let s = c.as_str()?; (!s.is_empty()).then_some(true) }
            else if c.is_array() { c.as_array().map(|a| !a.is_empty()).unwrap_or(false).then_some(true) }
            else { None }
        })
        // 兼容 LLM 常用格式：stages[].status == "completed"
        .or_else(|| {
            let stages = update.get("stages")?.as_array()?;
            let any_completed = stages.iter().any(|s| s.get("status").and_then(|v| v.as_str()) == Some("completed"));
            any_completed.then_some(true)
        })
        .unwrap_or(false);
    if task_complete {
        // ── 子阶段完整性检查 ──
        // 若任务有 sub_steps 但未全部 done，拒绝推进
        if let Some(stages_check) = plan["stages"].as_array() {
            for stage in stages_check {
                if stage["status"] == "in_progress" || stage["status"] == "pending" {
                    if let Some(tasks) = stage["tasks"].as_array() {
                        for task in tasks {
                            if task["status"] == "in_progress" {
                                if let Some(ss) = task.get("sub_steps") {
                                    let teach = ss["teach"].as_str().unwrap_or("pending");
                                    let examples = ss["examples"].as_str().unwrap_or("pending");
                                    let quiz = ss["quiz"].as_str().unwrap_or("pending");
                                    if teach != "done" || examples != "done" || quiz != "done" {
                                        tracing::warn!("[apply_plan_mutations] SUB_STEPS BLOCKED: teach={}, examples={}, quiz={}, task='{}', conv={}",
                                            teach, examples, quiz,
                                            task.get("name").and_then(|n| n.as_str()).unwrap_or("?"),
                                            conversation_id);
                                        return None; // 拒绝推进
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

        tracing::debug!("Plan mutation: current_task_complete=true (source: {})",
            if update.get("current_task_complete").and_then(|c| c.as_bool()).is_some() { "top-level" } else { "assessment" });
        if let Some(stages) = plan["stages"].as_array_mut() {
            for stage in stages.iter_mut() {
                let st_status = stage["status"].as_str().unwrap_or("pending");
                if st_status == "in_progress" || st_status == "pending" {
                    // 确保阶段是 in_progress（可能从 pending 激活）
                    if stage["status"] == "pending" {
                        stage["status"] = json!("in_progress");
                    }

                    if let Some(tasks) = stage["tasks"].as_array_mut() {
                        // 先找 in_progress 的任务；如果没有，激活第一个 pending 任务
                        let mut task_found = false;
                        let mut was_activated = false; // 标记：本次是从 pending 激活的，还是从 in_progress→done
                        for task in tasks.iter_mut() {
                            if task["status"] == "in_progress" {
                                task["status"] = json!("done");
                                task_found = true;
                                break;
                            }
                        }
                        if !task_found {
                            // 没有 in_progress 任务 → 激活第一个 pending 任务（推进到下一任务）
                            for task in tasks.iter_mut() {
                                if task["status"] == "pending" {
                                    task["status"] = json!("in_progress");
                                    task_found = true;
                                    was_activated = true;
                                    break;
                                }
                            }
                        }

                        if task_found {
                            // 当前 stage 所有 task 完成 → stage done
                            if tasks.iter().all(|t| t["status"] == "done") {
                                stage["status"] = json!("done");
                                // 如果有下一阶段建议 → 激活下一阶段
                                let next_activated = if let Some(next) = update.get("next_stage_suggestion")
                                    .and_then(|v| v.as_str())
                                {
                                    let mut activated = false;
                                    for s in stages.iter_mut() {
                                        if s["status"] == "pending" {
                                            let sname = s["name"].as_str().unwrap_or("");
                                            // 模糊匹配：next 包含 stage name 或 stage name 包含 next
                                            if sname.contains(next) || next.contains(sname) {
                                                s["status"] = json!("in_progress");
                                                if let Some(next_tasks) = s["tasks"].as_array_mut() {
                                                    if let Some(first) = next_tasks.first_mut() {
                                                        first["status"] = json!("in_progress");
                                                    }
                                                }
                                                activated = true;
                                                break;
                                            }
                                        }
                                    }
                                    activated
                                } else {
                                    false
                                };
                                // 无下一阶段建议时，自动激活下一个 pending stage
                                if !next_activated {
                                    for s in stages.iter_mut() {
                                        if s["status"] == "pending" {
                                            s["status"] = json!("in_progress");
                                            if let Some(next_tasks) = s["tasks"].as_array_mut() {
                                                if let Some(first) = next_tasks.first_mut() {
                                                    first["status"] = json!("in_progress");
                                                }
                                            }
                                            tracing::info!("Auto-activate next stage: {} (conv={})",
                                                s["name"].as_str().unwrap_or("?"), conversation_id);
                                            break;
                                        }
                                    }
                                }
                            } else if !was_activated {
                                // 阶段内还有未完成任务 → 自动激活下一个 pending 任务
                                // 仅当本次是从 in_progress→done 时执行（非 pending→in_progress 激活）
                                for t in tasks.iter_mut() {
                                    if t["status"] == "pending" {
                                        t["status"] = json!("in_progress");
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

    // LLM 超前更新回退：将当前 in_progress 任务回退到 pending，恢复上一 done 任务
    if update.get("reset_current_task").and_then(|v| v.as_bool()).unwrap_or(false) {
        if let Some(stages) = plan["stages"].as_array_mut() {
            for stage in stages.iter_mut() {
                if stage["status"] == "in_progress" {
                    if let Some(tasks) = stage["tasks"].as_array_mut() {
                        // 找到当前 in_progress 任务 → 回退为 pending
                        let mut current_idx = None;
                        for (i, task) in tasks.iter_mut().enumerate() {
                            if task["status"] == "in_progress" {
                                tasks[i]["status"] = json!("pending");
                                current_idx = Some(i);
                                break;
                            }
                        }
                        // 找到上一个 done 任务 → 恢复为 in_progress
                        if let Some(idx) = current_idx {
                            if idx > 0 {
                                for j in (0..idx).rev() {
                                    if tasks[j]["status"] == "done" {
                                        tasks[j]["status"] = json!("in_progress");
                                        break;
                                    }
                                }
                            }
                            // 如果本阶段没有上一个 done 任务，检查上一阶段
                            if tasks.iter().any(|t| t["status"] == "done") {
                                // 本阶段有 done 任务但 idx==0，说明 done 在前面被跳过了
                                // 这种情况不应该发生，但以防万一：找最后一个 done
                                if idx == 0 {
                                    for j in (0..tasks.len()).rev() {
                                        if tasks[j]["status"] == "done" {
                                            tasks[j]["status"] = json!("in_progress");
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        // 如果当前阶段全部 pending/done 且 stage 是 done，回退为 in_progress
                        if stage["status"] == "done" {
                            stage["status"] = json!("in_progress");
                        }
                        // 如果下一阶段是 in_progress，回退为 pending
                        // (需要在外部循环或后续逻辑中处理)
                    }
                    break;
                }
            }
        }
        tracing::debug!("Plan mutation: reset_current_task=true — task reverted");
    }

    // plan_content 只存结构，不存状态（sub_steps 已废弃，由 LLM prompt 管理）
    // 状态变化由 user_plan_progress 追踪
    // BUT: apply_plan_mutations 返回的 mutated plan 需要写回 plan_content，
    // 否则下次调用时从 plan_content 读取的仍是旧状态，无法正确推进
    if plan_id != "placeholder" && task_complete {
        let updated_content_str = plan.to_string();
        if let Err(e) = conn.execute(
            "UPDATE conversation_plans SET plan_content = ?1, updated_at = ?2 WHERE id = ?3",
            rusqlite::params![updated_content_str, chrono::Utc::now().timestamp(), plan_id],
        ) {
            tracing::warn!("[apply_plan_mutations] save plan_content failed: {}", e);
        }
    }

    Some(plan)
}

/// 从完整 plan 中提取 task → status 映射（用于 task_status 状态存储）
fn extract_task_status(plan: &serde_json::Value) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
        for stage in stages {
            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                        let status = task.get("status").and_then(|s| s.as_str()).unwrap_or("pending");
                        map.insert(name.to_string(), serde_json::json!(status));
                    }
                }
            }
        }
    }
    serde_json::Value::Object(map)
}

/// 检测用户消息是否包含回退信号关键词
///
/// 当 LLM 未能主动使用 reset_current_task 时，
/// 由代码层自动检测并触发回退。
/// 回退计划：精确匹配 /back 命令，直接操作 user_plan_progress 回滚一步。
/// 不做 LLM 调用，不写 plan_content，只修改 user_plan_progress 状态。
/// 返回 true 表示回滚成功。
pub fn auto_revert(conn: &rusqlite::Connection, conversation_id: &str, user_message: &str) -> bool {
    if user_message.trim() != "/back" {
        return false;
    }

    // 获取 plan_id
    let plan_id: String = match conn.query_row(
        "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
        rusqlite::params![conversation_id],
        |row| row.get(0),
    ) {
        Ok(id) => id,
        Err(_) => return false,
    };

    // 按 task_key 排序，找到当前 in_progress 和上一个 done 的任务
    let tasks: Vec<(String, String)> = {
        let mut stmt = match conn.prepare(
            "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1 ORDER BY task_key ASC"
        ) {
            Ok(s) => s,
            Err(_) => return false,
        };
        stmt.query_map(rusqlite::params![plan_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    };

    if tasks.is_empty() {
        return false;
    }

    let mut current_idx: Option<usize> = None;
    for (i, (_, status)) in tasks.iter().enumerate() {
        if status == "in_progress" {
            current_idx = Some(i);
            break;
        }
    }

    let current_idx = match current_idx {
        Some(i) => i,
        None => return false, // 没有 in_progress 的任务
    };

    if current_idx == 0 {
        // 第一个任务就是 in_progress，没有可回退的前置任务
        return false;
    }

    let prev_idx = current_idx - 1;
    if tasks[prev_idx].1 != "done" {
        // 前一个任务不是 done 状态，说明状态异常，不操作
        return false;
    }

    let now = chrono::Utc::now().timestamp();
    let (current_key, _) = &tasks[current_idx];
    let (prev_key, _) = &tasks[prev_idx];

    // 当前 in_progress → pending
    let _ = conn.execute(
        "UPDATE user_plan_progress SET status = 'pending', updated_at = ?1 WHERE plan_id = ?2 AND task_key = ?3",
        rusqlite::params![now, plan_id, current_key],
    );
    // 上一个 done → in_progress
    let _ = conn.execute(
        "UPDATE user_plan_progress SET status = 'in_progress', updated_at = ?1 WHERE plan_id = ?2 AND task_key = ?3",
        rusqlite::params![now, plan_id, prev_key],
    );

    tracing::info!("Auto-revert applied: {} → pending, {} → in_progress (conv={})", current_key, prev_key, conversation_id);
    true
}

// ════════════════════════════════════════════
// Coldpath 2：自动推进评估
// ════════════════════════════════════════════

/// 强制创建计划 — 给 /plan 命令使用。
/// 与 analyze_turn_progress(无 plan 分支) 逻辑一致，但跳过 signal 检测直接创建。
pub async fn force_plan_creation(conversation_id: &str, user_intent: &str) -> bool {
    let dialogue_text = {
        let conn = crate::db_pool::get_conn();
        let mut stmt = match conn.prepare(
            "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at ASC"
        ) {
            Ok(s) => s,
            Err(_) => return false,
        };
        let turns: Vec<(String, String)> = stmt.query_map(
            rusqlite::params![conversation_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        ).unwrap().filter_map(|r| r.ok()).collect();

        let mut dialogue = String::new();
        // 如果带了参数（如 /plan 学习二次函数），优先放入对话上下文
        if !user_intent.is_empty() {
            dialogue.push_str(&format!("学生: 我想学习{}\n", user_intent));
        }
        for (role, content) in turns.iter() {
            if role == "user" || role == "assistant" {
                let label = if role == "user" { "学生" } else { "教师" };
                dialogue.push_str(&format!("{}: {}\n", label, content));
            }
        }
        dialogue
    };

    if dialogue_text.is_empty() {
        return false;
    }

    let prompt = build_plan_creation_prompt(&dialogue_text);
    let config = crate::llm::get_config();
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);
    let response = caller.generate("", &prompt).await;

    match response {
        Ok(reply) => {
            let conn = crate::db_pool::get_conn();
            // conversation_id 传 "" 作为 user_id（upsert_learning_plan 会重新查）
            let result = handle_plan_update(&conn, &format!("<plan_update>{}</plan_update>", reply), conversation_id, "");
            if result.is_new_plan || result.plan_updated {
                // 激活第一个 stage 的卡片
                if let Some(ref plan) = result.task_status {
                    let user_id: String = conn.query_row(
                        "SELECT user_id FROM conversations WHERE id = ?1",
                        rusqlite::params![conversation_id],
                        |row| row.get(0),
                    ).unwrap_or_default();
                    let plan_id: String = conn.query_row(
                        "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                        rusqlite::params![conversation_id],
                        |row| row.get(0),
                    ).unwrap_or_default();
                    if !plan_id.is_empty() && !user_id.is_empty() {
                        if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
                            if let Some(first_stage) = stages.first() {
                                if let Some(tasks) = first_stage.get("tasks").and_then(|t| t.as_array()) {
                                    for task in tasks {
                                        let task_key = task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
                                        for cid in task.get("card_ids").and_then(|c| c.as_array()).into_iter().flatten() {
                                            if let Some(card_uuid) = cid.as_str() {
                                                crate::plan_handler::copy_prebuilt_card(&conn, &user_id, &plan_id, conversation_id, task_key, card_uuid);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return true;
            }
            false
        }
        Err(_) => false,
    }
}

/// 每 5 轮对话后由 ws.rs 调用，分析最近对话历史判断学生是否应推进到下一任务。
/// 不修改任何数据，只返回评估结论。调用方负责注入标签和执行更新。
pub fn build_plan_context(conn: &rusqlite::Connection, conversation_id: &str) -> (String, String, String) {
    eprintln!("[MARK] build_plan_context ENTER");
    // 不再查询 conversations.subject/grade_band 或 plan_templates（已废弃）

    // 从 conversation_plans 读取
    if let Ok((goal, plan_content_str)) = conn.query_row(
        "SELECT goal, plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
    ) {
        let plan_content = plan_content_str.unwrap_or_default();
        let mut merged: serde_json::Value = serde_json::from_str(&plan_content).unwrap_or_default();

        // 从 user_plan_progress 读取进度
        let cp_plan_id: String = conn.query_row(
            "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![conversation_id],
            |row| row.get(0),
        ).unwrap_or_default();

        if !cp_plan_id.is_empty() {
            let progress_rows: Vec<(String, String)> = {
                let mut stmt = conn.prepare(
                    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
                ).unwrap();
                stmt.query_map(rusqlite::params![cp_plan_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).unwrap().filter_map(|r| r.ok()).collect()
            };
            let progress_map: std::collections::HashMap<String, String> = progress_rows.into_iter().collect();

            // 合并进度到 plan_content stages
            if let Some(stages) = merged.get_mut("stages").and_then(|s| s.as_array_mut()) {
                for stage in stages.iter_mut() {
                    if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                        let mut stage_done = true;
                        let mut stage_has_active = false;
                        let mut stage_has_pending = false;
                        for task in tasks.iter_mut() {
                            let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                            let state = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                            task["status"] = serde_json::json!(state);
                            match state {
                                "in_progress" => stage_has_active = true,
                                "pending" => stage_has_pending = true,
                                _ => {}
                            }
                            if state != "done" && state != "skipped" {
                                stage_done = false;
                            }
                        }
                        stage["status"] = if stage_done { serde_json::json!("done") }
                            else if stage_has_active { serde_json::json!("in_progress") }
                            else if stage_has_pending { serde_json::json!("pending") }
                            else { serde_json::json!("done") };
                    }
                }
            }
        }

        // 从 plan_content 读取 prompt_mode 确定 mode 和 subject/domain
        let first_prompt_mode = merged.get("stages")
            .and_then(|s| s.as_array())
            .and_then(|stages| stages.first())
            .and_then(|stage| stage.get("tasks"))
            .and_then(|t| t.as_array())
            .and_then(|tasks| tasks.first())
            .and_then(|task| task.get("prompt_mode"))
            .and_then(|p| p.as_str())
            .unwrap_or("general/structured");

        let mode = first_prompt_mode.split('/').nth(1).unwrap_or("structured").to_string();

        let prompt_subject = first_prompt_mode.split('/').next().unwrap_or("general").to_string();

        let pipeline_domain: String = merged.get("pipeline_domain")
            .and_then(|d| d.as_str())
            .or_else(|| merged.get("domain").and_then(|d| d.as_str()))
            .unwrap_or(&prompt_subject)
            .to_string();

        let ctx = build_context_text(&merged, &goal, &mode);
        return (pipeline_domain, mode.to_string(), ctx);
    }

    // 无计划
    ("".to_string(), "free".to_string(), String::new())
}

/// 从 merged plan JSON（含 status 已合并的 stages）构建 LLM 上下文文本
fn build_context_text(merged: &serde_json::Value, goal: &str, _mode: &str) -> String {
    let _ = _mode; // suppress unused warning — kept for future use
    let mut ctx = format!("\n\n### 学习计划\n长期目标: {}", goal);
    let mut current_task_name: Option<String> = None;
    let mut current_stage_name: Option<String> = None;

    // 统一处理所有模式：遍历 stages/tasks，注入 status
    if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
        let mut found_current = false;
        let mut next_stage_name: Option<String> = None;
        for stage in stages {
            let name = stage["name"].as_str().unwrap_or("");
            let status = stage["status"].as_str().unwrap_or("pending");
            if status == "in_progress" || status == "pending" {
                if !found_current {
                    found_current = true;
                    current_stage_name = Some(name.to_string());
                    ctx.push_str(&format!("\n当前阶段: {} ({})", name, status));
                    if let Some(tasks) = stage["tasks"].as_array() {
                        for task in tasks {
                            let tname = task["name"].as_str().unwrap_or("");
                            let tstatus = task["status"].as_str().unwrap_or("pending");
                            ctx.push_str(&format!("\n  - {}: {}", tname, tstatus));
                            // 第一个 in_progress 的 task 即为当前任务
                            if tstatus == "in_progress" && current_task_name.is_none() {
                                current_task_name = Some(tname.to_string());
                            }
                        }
                        // 如果当前 stage 一个 in_progress 都没有（全部 pending），取第一个 task
                        if current_task_name.is_none() {
                            if let Some(first) = stage["tasks"].as_array().and_then(|t| t.first()) {
                                current_task_name = first["name"].as_str().map(|s| s.to_string());
                            }
                        }
                    }
                } else {
                    next_stage_name = Some(name.to_string());
                    break;
                }
            }
        }
        if let Some(ref next) = next_stage_name {
            ctx.push_str(&format!("\n下一阶段: {}", next));
        }
    }

    // 动态注入任务完成指令（基于真实的当前任务名）
    if let Some(ref task_name) = current_task_name {
        ctx.push_str(&format!(
            "\n\n### 任务完成信号\n\
             当前需要完成的任务是：{}\n\
             此任务教学完毕后，在你回复末尾输出：**{} ✅ 已完成**\n\
             系统检测到此信号后将自动推进到下一任务。{}",
            task_name,
            task_name,
            if let Some(ref stage_name) = current_stage_name {
                format!("\n如果当前阶段 {} 的所有任务都已依次完成，请为每个任务分别输出完成信号。", stage_name)
            } else {
                String::new()
            }
        ));
    }

    // 写入 context 日志缓冲区（供 e2e 测试捕获）
    if let Ok(mut log) = CONTEXT_LOG.lock() {
        log.push(ctx.clone());
    }

    eprintln!("[MARK] build_plan_context EXIT");
    ctx
}
/// 构建计划创建 prompt（从 prompts/plan/{domain}/creation.md 加载，fallback 到 general）
pub fn build_plan_creation_prompt(dialogue_text: &str) -> String {
    let tpl = chat_engine::prompt_loader::get_plan("general").creation.clone();
    if tpl.is_empty() {
        // 降级：硬编码兜底
        let default = r#"根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{dialogue_text}

请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可，如"一元二次方程求解"、"Python入门"）
- stages: 阶段数组，每个阶段包含 name、tasks 数组
- 每项 task 包含 name、description
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

确保计划包含 3-5 个阶段，每个阶段 2-3 个任务，覆盖完整的学习路径。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}
"#;
        default.replace("{dialogue_text}", dialogue_text)
    } else {
        tpl.replace("{dialogue_text}", dialogue_text)
    }
}

/// ❄️ CP2 轻量版：每轮检测，只用 teacher 最后一轮回复
pub async fn analyze_turn_progress(
    conversation_id: &str,
    user_id: &str,
    caller: &mut chat_engine::llm_caller::LlmCaller,
    final_reply: &str,
) -> bool {
    let (has_plan, _mode) = {
        let conn = crate::db_pool::get_conn();
        match conn.query_row(
            "SELECT 1 FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![conversation_id],
            |_| Ok(()),
        ) {
            Ok(_) => (true, String::new()),
            Err(_) => (false, String::new()),
        }
    };

    // 获取 domain（从 conversation_plans.subject）
    let domain: String = {
        let conn = crate::db_pool::get_conn();
        conn.query_row(
            "SELECT subject FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![conversation_id],
            |row| row.get::<_, String>(0),
        ).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "general".to_string())
    };

    if !has_plan {
        // ── 无 plan：先用 final_reply 快速轻量检测是否引入了学习任务 ──
        // 有信号时回退到对话全量历史创建 plan（因 plan 创建需要完整上下文）
        let signal_prompt = chat_engine::prompt_loader::get_plan(&domain).signal
            .replace("{final_reply}", final_reply);
        let has_signal = match caller.generate("", &signal_prompt).await {
            Ok(response) => {
                if let Some(start) = response.find('{') {
                    if let Some(end) = response[start..].find('}') {
                        let json_str = &response[start..=start + end];
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(json_str) {
                            v.get("has_task").and_then(|b| b.as_bool()).unwrap_or(false)
                        } else { false }
                    } else { false }
                } else { false }
            }
            Err(_) => false,
        };

        if has_signal {
            // 有引入信号 → 读取对话全量历史，调用现有 plan creation
            let dialogue_text = {
                let conn = crate::db_pool::get_conn();
                let mut stmt = match conn.prepare(
                    "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at ASC"
                ) {
                    Ok(s) => s,
                    Err(_) => return false,
                };
                let turns: Vec<(String, String)> = stmt.query_map(
                    rusqlite::params![conversation_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                ).unwrap().filter_map(|r| r.ok()).collect();
                turns.iter()
                    .filter(|(r, _)| r == "user" || r == "assistant")
                    .map(|(role, content)| {
                        let label = if role == "user" { "学生" } else { "教师" };
                        format!("{}: {}", label, content)
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            let prompt = build_plan_creation_prompt(&dialogue_text);
            match caller.generate("", &prompt).await {
                Ok(response) => {
                    let conn = crate::db_pool::get_conn();
                    let result = handle_plan_update(&conn, &format!("<plan_update>{}</plan_update>", response), conversation_id, user_id);
                    if result.is_new_plan || result.plan_updated {
                        if let Some(ref updated_plan) = result.task_status {
                            unlock_next_cards(&conn, conversation_id, user_id, updated_plan);
                        }
                        tracing::info!("CP2 created plan from final_reply signal");
                        return true;
                    }
                }
                Err(e) => tracing::error!("CP2 analyze_turn_progress (create plan): LLM call failed: {:?}", e),
            }
        }
        return false;
    } else {

    //     ── 有 plan：检测 teacher 是否完成了当前任务 ──

        // 读取 plan + progress，获取当前 in_progress 任务名
        let current_task_name: Option<String> = 'task_name: {
            let conn = crate::db_pool::get_conn();
            let (goal, plan_content_str) = match conn.query_row(
                "SELECT goal, plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                rusqlite::params![conversation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            ) {
                Ok(v) => v,
                Err(_) => break 'task_name None,
            };
            let plan_content = plan_content_str.unwrap_or_default();
            let mut merged: serde_json::Value = serde_json::from_str(&plan_content).unwrap_or_default();
            let cp_plan_id: String = conn.query_row(
                "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
                rusqlite::params![conversation_id],
                |row| row.get(0),
            ).unwrap_or_default();
            if cp_plan_id.is_empty() {
                break 'task_name None;
            }
            let progress_rows: Vec<(String, String)> = conn.prepare(
                "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
            ).ok().and_then(|mut stmt| {
                stmt.query_map(rusqlite::params![cp_plan_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect())
            }).unwrap_or_default();
            let progress_map: HashMap<String, String> = progress_rows.into_iter().collect();

            if let Some(stages) = merged.get_mut("stages").and_then(|s| s.as_array_mut()) {
                for stage in stages {
                    if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                        for task in tasks {
                            let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                            let state = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                            task["status"] = serde_json::json!(state);
                            if state == "in_progress" {
                                break 'task_name task.get("name").and_then(|n| n.as_str()).map(|s| s.to_string());
                            }
                        }
                    }
                }
            }
            break 'task_name None;
        };

        // ★★ Fast Path: 精确匹配通关信号
        // 使用从 DB 查到的当前任务名，与 LLM 回复中的 badge 精确匹配
        let badge_found = if let Some(ref task_name) = current_task_name {
            let expected_badge = format!("**{} ✅ 已完成**", task_name);
            final_reply.contains(&expected_badge)
        } else {
            false
        };

        if badge_found {
            // 任务名直接从 DB 查询得到，不再从回复中模糊提取
            let task_name = current_task_name.unwrap_or_default();

            let conn = crate::db_pool::get_conn();
            let update_json = serde_json::json!({
                "current_task_complete": true,
                "completed_concepts": [task_name],
            });
            let plan_update_str = format!("<plan_update>{}</plan_update>", update_json);
            let result = handle_plan_update(&conn, &plan_update_str, conversation_id, user_id);
            if result.plan_updated {
                tracing::info!("CP2 badge triggered: task='{}'", task_name);
                unlock_next_cards(&conn, conversation_id, user_id, &result.task_status.unwrap_or_default());
                return true;
            }
        }

        // ── LLM 分析已移除（由通关信号驱动，语义理解由 teacher prompt 保证）──
        false
    }
}

/// 卡片渐进解锁：当任务完成后，解锁下一批预置卡片
fn unlock_next_cards(
    conn: &rusqlite::Connection,
    conversation_id: &str,
    user_id: &str,
    task_status: &serde_json::Value,
) {
    // 从计划中找下一个 task（当前完成后面第一个 in_progress/pending）
    let next_task: Option<&serde_json::Value> = (|| {
        let stages = task_status.get("stages").and_then(|v| v.as_array())?;
        let mut found_complete = false;
        for stage in stages {
            let tasks = stage.get("tasks").and_then(|v| v.as_array())?;
            for task in tasks {
                let status = task.get("status").and_then(|v| v.as_str()).unwrap_or("pending");
                if status == "in_progress" || status == "pending" {
                    if !found_complete {
                        let task_name = task.get("name").and_then(|v| v.as_str()).unwrap_or("");
                        if crate::k12_quiz::should_mark_task_complete(conn, user_id, task_name) {
                            found_complete = true;
                            continue;
                        }
                        return None;
                    }
                    return Some(task);
                }
            }
        }
        None
    })();

    let next_task = match next_task {
        Some(t) => t,
        None => return,
    };

    let now_ts = chrono::Utc::now().timestamp();

    // 获取 plan_id
    let plan_id: String = conn.query_row(
        "SELECT cp.id FROM conversation_plans cp WHERE cp.conversation_id = ?1 LIMIT 1",
        rusqlite::params![conversation_id],
        |row| row.get(0),
    ).unwrap_or_default();

    // ── V3 统一路径: card_ids（UUID）──
    // 所有卡片在 init 时已通过 copy_prebuilt_card 预拷贝到用户名下
    // 此处只做 status 激活（archived → active）
    let card_ids: Vec<String> = next_task.get("card_ids")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();

    if !card_ids.is_empty() {
        let task_key = next_task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
        for cid in &card_ids {
            // 使用 copy_prebuilt_card 确保卡片已存在（幂等）
            crate::plan_handler::copy_prebuilt_card(conn, user_id, &plan_id, conversation_id, task_key, cid);
        }
        return;
    }

    // ── 激活当前 in_progress stage 的卡片 ──
    if let Some(stages) = task_status.get("stages").and_then(|s| s.as_array()) {
        for stage in stages {
            if stage["status"] == "in_progress" || stage["status"] == "done" {
                if let Some(sn) = stage["name"].as_str() {
                    let plan_id: String = conn.query_row(
                        "SELECT COALESCE((SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1), '')",
                        rusqlite::params![conversation_id],
                        |row| row.get(0),
                    ).unwrap_or_default();
                    if plan_id.is_empty() { break; }
                    activate_stage_cards(conn, &user_id, "", &plan_id, sn);
                }
                break;
            }
        }
    }
}

/// 从 plan_update JSON 渲染学习计划文本
pub fn render_plan(plan: &serde_json::Value) -> String {
    let goal = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("学习计划");
    let empty_vec: Vec<serde_json::Value> = vec![];
    let stages = plan.get("stages").and_then(|v| v.as_array()).unwrap_or(&empty_vec);

    let mut out = format!("好的！我来为你制定一个学习计划 📋\n\n**目标：{}**\n", goal);

    for stage in stages.iter() {
        let name = stage["name"].as_str().unwrap_or("");
        let status = stage["status"].as_str().unwrap_or("pending");
        let icon = if status == "in_progress" { "🔄" } else if status == "done" { "✅" } else { "📌" };
        out.push_str(&format!("\n### {} {} \n", icon, name));

        if let Some(tasks) = stage["tasks"].as_array() {
            for task in tasks.iter() {
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


/// 从 v3 预置数据复制一张卡片到用户名下
use std::sync::OnceLock;

/// 全局预置卡缓存（UUID → JSON Value），首次调用时惰性加载
static PREBUILT_CARD_CACHE: OnceLock<std::collections::HashMap<String, serde_json::Value>> = OnceLock::new();

fn load_prebuilt_card_cache() -> &'static std::collections::HashMap<String, serde_json::Value> {
    eprintln!("[CACHE] loading prebuilt cards...");
    PREBUILT_CARD_CACHE.get_or_init(|| {
        let data_dir = crate::curriculum_loader::k12_data_dir();
        let mut map = std::collections::HashMap::new();
        for search_dir in &[data_dir.join("cards"), data_dir.join("cards").join("reading")] {
            if let Ok(entries) = std::fs::read_dir(search_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) != Some("json") { continue; }
                    if let Ok(content) = std::fs::read_to_string(&path) {
                        if let Ok(data) = serde_json::from_str::<serde_json::Value>(&content) {
                            if let Some(cards) = data.get("cards").and_then(|c| c.as_array()) {
                                for card in cards {
                                    if let Some(cid) = card["id"].as_str() {
                                        map.insert(cid.to_string(), card.clone());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        tracing::info!("[copy_prebuilt_card] loaded {} prebuilt cards into cache", map.len());
        eprintln!("[CACHE] loaded {} cards", map.len());
        map
    })
}

pub fn copy_prebuilt_card(
    conn: &rusqlite::Connection,
    user_id: &str,
    plan_id: &str,
    conversation_id: &str,
    task_key: &str,
    card_uuid: &str,
) {
    let cache = load_prebuilt_card_cache();
    if let Some(card) = cache.get(card_uuid) {
        let now = chrono::Utc::now().timestamp();
        let _ = conn.execute(
            "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, plan_id, task_key)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            rusqlite::params![
                card_uuid, user_id,
                card["domain"].as_str().unwrap_or(""),
                card["card_type"].as_str().unwrap_or(""),
                card["front"].as_str().unwrap_or(""),
                card["back"].as_str().unwrap_or(""),
                card["source_sentence"].as_str().unwrap_or(""),
                if conversation_id.is_empty() { None } else { Some(conversation_id) },
                now, plan_id,
                if task_key.is_empty() { None } else { Some(task_key) },
            ],
        );
        let _ = conn.execute(
            "INSERT OR IGNORE INTO card_memory (card_id, state, status, difficulty, stability, due, last_review, reps, lapses)
             VALUES (?1, 0, 'active', 0.3, 1.0, ?2, 0, 0, 0)",
            rusqlite::params![card_uuid, now],
        );
    } else {
        tracing::warn!("[copy_prebuilt_card] card not found: {}", card_uuid);
    }
}

/// 激活指定 stage 的所有卡片（archived → active）
/// 在 K12 init 完成时、或 stage 状态变为 in_progress 时调用
pub fn activate_stage_cards(
    conn: &rusqlite::Connection,
    user_id: &str,
    _plan_type: &str,
    plan_id: &str,
    stage_name: &str,
) {
    if plan_id.is_empty() || stage_name.is_empty() || user_id.is_empty() {
        return;
    }
    // V3 简化：卡片已在 copy_prebuilt_card 时设 status='active'
    // 旧管道通过卡片 ID 前缀（vocab_/reading_/k12_）查找并激活
    // 此处仅记录日志（列已不存在，不做 SQL 更新）
    tracing::info!("Activate stage '{}' (plan={}): cards already pre-copied", stage_name, plan_id);
    let _ = _plan_type; // suppress unused warning
}

/// 修复 LLM 输出 JSON 中的常见转义错误
///
/// LLM（特别是 DeepSeek V4 Flash）在生成 JSON 时可能输出未转义的反斜杠，
/// 例如 description 字段中的 `\d`、`\w`、`\n`（字面量）等。
/// JSON 规范要求 `\` 后只能跟 `"`, `\`, `/`, `b`, `f`, `n`, `r`, `t`, `uXXXX`。
///
/// 此函数将字符串值内所有不是合法 JSON 转义序列的 `\` 替换为 `\\`。
fn repair_json_backslashes(json_str: &str) -> String {
    let mut result = String::with_capacity(json_str.len());
    let chars: Vec<char> = json_str.chars().collect();
    let mut i = 0;
    let mut in_string = false;

    while i < chars.len() {
        let ch = chars[i];
        match ch {
            '"' if i == 0 || chars[i - 1] != '\\' => {
                in_string = !in_string;
                result.push(ch);
            }
            '\\' if in_string => {
                // 检查下一个字符是否为合法 JSON 转义
                let valid_escape = i + 1 < chars.len() && matches!(
                    chars[i + 1],
                    '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' | 'u'
                );
                if valid_escape {
                    result.push(ch); // 合法转义，原样保留
                } else {
                    result.push_str("\\\\"); // 非法转义，双写反斜杠
                    i += 1; // 跳过 \，但用 continue 避免底部 i++ 吞掉下一个字符
                    continue;
                }
            }
            _ => {
                result.push(ch);
            }
        }
        i += 1;
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_repair_json_backslashes() {
        // 正常 JSON 不应被修改
        let ok = r#"{"key": "hello world"}"#;
        assert_eq!(repair_json_backslashes(ok), ok);

        // 合法转义不应被修改
        let ok2 = r#"{"key": "hello\nworld"}"#;
        assert_eq!(repair_json_backslashes(ok2), ok2);

        // 非法转义应被修复
        let bad = r#"{"desc": "使用 \d 匹配数字"}"#;
        let fixed = repair_json_backslashes(bad);
        assert_eq!(fixed, r#"{"desc": "使用 \\d 匹配数字"}"#);
        // 修复后应能解析
        assert!(serde_json::from_str::<serde_json::Value>(&fixed).is_ok());

        // 多个非法转义
        let bad2 = r#"{"desc": "正则 \d 和 \w"}"#;
        let fixed2 = repair_json_backslashes(bad2);
        assert_eq!(fixed2, r#"{"desc": "正则 \\d 和 \\w"}"#);

        // Windows 路径：\U 非法需修复，\t 合法保持
        let bad3 = r#"{"path": "C:\Users\test"}"#;
        let fixed3 = repair_json_backslashes(bad3);
        assert_eq!(fixed3, r#"{"path": "C:\\Users\test"}"#);

        // 回归测试：非法转义不应导致无限循环 (BugFix 2026-05-16)
        let bad4 = r#"{"key": "\d\w"}"#;
        let fixed4 = repair_json_backslashes(bad4);
        assert_eq!(fixed4, r#"{"key": "\\d\\w"}"#);
        assert!(serde_json::from_str::<serde_json::Value>(&fixed4).is_ok());

        // 回归测试：长字符串不卡死
        let bad5 = format!(r#"{{"k": "{}"}}"#, "\\d".repeat(100));
        let _ = repair_json_backslashes(&bad5); // 不挂即可
    }

    #[test]
    fn test_current_task_complete_in_assessment() {
        // 验证 LLM 将 current_task_complete 嵌套在 assessment 内时也能识别
        use crate::plan_handler::handle_plan_update;
        use rusqlite::Connection;
        use serde_json::json;

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE users (id TEXT PRIMARY KEY);
            CREATE TABLE conversations (id TEXT PRIMARY KEY);
            CREATE TABLE conversation_plans (id TEXT, user_id TEXT, conversation_id TEXT NOT NULL UNIQUE, goal TEXT, subject TEXT DEFAULT '', plan_content TEXT, created_at INTEGER, updated_at INTEGER);
            INSERT INTO users VALUES ('u1');
            INSERT INTO conversations VALUES ('c1');
            INSERT INTO conversation_plans VALUES ('p1', 'u1', 'c1', 'test', '', '', NULL, 0, 0);
        ").unwrap();

        // 初始计划：Task1 in_progress, Task2 pending
        let plan_content = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "in_progress", "task_key": "Task1"},
                    {"name": "Task2", "status": "pending", "task_key": "Task2"}
                ]
            }],
            "completed_concepts": []
        });
        conn.execute("UPDATE conversation_plans SET plan_content=?1 WHERE conversation_id='c1'",
            rusqlite::params![plan_content.to_string()]).unwrap();

        // LLM 格式漂移：current_task_complete 嵌套在 assessment 内，顶层无此字段
        let reply = format!("回答内容\n\n<plan_update>\n{}\n</plan_update>", json!({
            "completed_concepts": ["概念1"],
            "assessment": {
                "task": "Task1",
                "passed": true,
                "current_task_complete": true
            }
        }));

        let result = handle_plan_update(&conn, &reply, "c1", "u1");
        assert!(result.plan_updated, "plan should be updated");

        let plan = result.task_status.unwrap();
        let tasks = plan["stages"][0]["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["status"], "done", "Task1 should be marked done");
        assert_eq!(tasks[1]["status"], "in_progress", "Task2 should be activated");
    }

    #[test]
    fn test_reset_current_task_revert() {
        // 验证 LLM 超前更新后可以通过 reset_current_task 回退
        use crate::plan_handler::handle_plan_update;
        use rusqlite::Connection;
        use serde_json::json;

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE users (id TEXT PRIMARY KEY);
            CREATE TABLE conversations (id TEXT PRIMARY KEY);
            CREATE TABLE conversation_plans (id TEXT, user_id TEXT, conversation_id TEXT NOT NULL UNIQUE, goal TEXT, subject TEXT DEFAULT '', plan_content TEXT, created_at INTEGER, updated_at INTEGER);
            INSERT INTO users VALUES ('u1');
            INSERT INTO conversations VALUES ('c1');
            INSERT INTO conversation_plans VALUES ('p1', 'u1', 'c1', 'test', '', '', NULL, 0, 0);
        ").unwrap();

        // 模拟超前更新后的状态：Task1 done, Task2 in_progress（但用户实际还没学完 Task1）
        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "done", "task_key": "Task1"},
                    {"name": "Task2", "status": "in_progress", "task_key": "Task2"}
                ]
            }],
            "completed_concepts": ["概念1"]
        });
        conn.execute("UPDATE conversation_plans SET plan_content=?1 WHERE conversation_id='c1'",
            rusqlite::params![plan.to_string()]).unwrap();

        // LLM 意识到超前，发送回退
        let reply = format!("抱歉我跳得太快了\n\n<plan_update>\n{}\n</plan_update>", json!({
            "reset_current_task": true
        }));

        let result = handle_plan_update(&conn, &reply, "c1", "u1");
        assert!(result.plan_updated, "plan should be updated");

        let plan = result.task_status.unwrap();
        let tasks = plan["stages"][0]["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["status"], "in_progress", "Task1 should be restored to in_progress");
        assert_eq!(tasks[1]["status"], "pending", "Task2 should be reverted to pending");
    }

    #[test]


    #[test]
    fn test_sub_steps_block_completion() {
        // 子阶段（sub_steps）已废弃（LLM prompt 管理子阶段），
        // 但解析逻辑保留向后兼容：sub_steps 未全部 done 时 current_task_complete 被拒绝。
        // 注意：sub_steps 变更不再持久化（plan_content 只存结构），
        // 所以本测试仅验证单次调用的阻断逻辑，不验证跨轮持久化。
        use rusqlite::Connection;
        use serde_json::json;

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE users (id TEXT PRIMARY KEY);
            CREATE TABLE conversations (id TEXT PRIMARY KEY);
            CREATE TABLE conversation_plans (id TEXT, user_id TEXT, conversation_id TEXT NOT NULL UNIQUE, goal TEXT, subject TEXT DEFAULT '', plan_content TEXT, created_at INTEGER, updated_at INTEGER);
            INSERT INTO users VALUES ('u1');
            INSERT INTO conversations VALUES ('c1');
            INSERT INTO conversation_plans VALUES ('p1', 'u1', 'c1', 'test', '', '', NULL, 0, 0);
        ").unwrap();

        // 任务含 sub_steps 但 quiz 未完成 → 阻断
        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [{
                    "name": "Task1", "status": "in_progress", "task_key": "Task1",
                    "sub_steps": {"teach": "done", "examples": "done", "quiz": "pending"}
                }]
            }],
            "completed_concepts": []
        });
        conn.execute("UPDATE conversation_plans SET plan_content=?1 WHERE conversation_id='c1'",
            rusqlite::params![plan.to_string()]).unwrap();

        // 尝试推进 — 应被拒绝
        let reply = format!("<plan_update>\n{}\n</plan_update>", json!({
            "current_task_complete": true
        }));
        let result = handle_plan_update(&conn, &reply, "c1", "u1");
        assert!(!result.plan_updated, "sub_steps incomplete → should block");

        // 直接设置 sub_steps 全部 done 后再尝试推进
        let plan2 = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [{
                    "name": "Task1", "status": "in_progress", "task_key": "Task1",
                    "sub_steps": {"teach": "done", "examples": "done", "quiz": "done"}
                }]
            }],
            "completed_concepts": []
        });
        conn.execute("UPDATE conversation_plans SET plan_content=?1 WHERE conversation_id='c1'",
            rusqlite::params![plan2.to_string()]).unwrap();

        // sub_steps 全部 done → 应通过
        let reply3 = format!("<plan_update>\n{}\n</plan_update>", json!({
            "current_task_complete": true
        }));
        let result3 = handle_plan_update(&conn, &reply3, "c1", "u1");
        assert!(result3.plan_updated, "sub_steps all done → should complete");
        assert_eq!(result3.task_status.unwrap()["stages"][0]["tasks"][0]["status"], "done");
    }
}
