//! 学习计划处理 — WebSocket 和 REST 共用模块
//!
//! 负责:
//!   1. 解析 LLM 回复中的 <plan_update>...</plan_update> XML 标签
//!   2. 创建/更新 learning_plans 表
//!   3. 返回清理后的回复文本

use serde_json::json;

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
/// - 成就检测（write_achievement）
/// - 发送 WebSocket 通知
pub fn handle_plan_update(
    conn: &rusqlite::Connection,
    raw_reply: &str,
    conversation_id: &str,
    user_id: &str,
) -> PlanUpdateResult {
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
                    } else {
                        if let Some(plan) = apply_plan_mutations(conn, conversation_id, &update) {
                            task_status = Some(plan.clone());
                            plan_updated = true;
                            // 同步推进结果到 user_plan_progress（apply_plan_mutations 只写 learning_plans）
                            if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
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
                                                    let cp_count: i64 = conn.query_row(
                                                        "SELECT COUNT(*) FROM conversation_plans WHERE conversation_id = ?1",
                                                        rusqlite::params![conversation_id], |r| r.get(0),
                                                    ).unwrap_or(-1);
                                                    let upp_count: i64 = conn.query_row(
                                                        "SELECT COUNT(*) FROM user_plan_progress WHERE task_key = ?1 AND plan_id IN (SELECT id FROM conversation_plans WHERE conversation_id = ?2)",
                                                        rusqlite::params![task_key, conversation_id], |r| r.get(0),
                                                    ).unwrap_or(-1);
                                                    eprintln!("[CP2 SYNC] 0 rows: task_key='{}' status='{}' conv='{}' cp_rows={} upp_matching={}", task_key, status, conversation_id, cp_count, upp_count);
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

    // ── reading_update 标签：标记当前 task 为 completed ──
    if let Some(start) = final_reply.find("<reading_update") {
        if let Some(tag_end) = final_reply[start..].find('>') {
            let content_start = start + tag_end + 1;
            if let Some(end) = final_reply[content_start..].find("</reading_update>") {
                let json_str = final_reply[content_start..content_start + end].to_string();
                final_reply.replace_range(start..content_start + end + 17, "");

                // 预期格式: {"complete_current_task": true}
                if let Ok(update) = serde_json::from_str::<serde_json::Value>(&json_str) {
                    if update.get("complete_current_task").and_then(|v| v.as_bool()).unwrap_or(false) {
                        plan_updated = true;
                        // 读取 task_status（task_status 映射）和 plan_content（任务顺序）
                        if let Ok((task_status_str, plan_content_raw)) = conn.query_row(
                            "SELECT task_status, plan_content FROM learning_plans WHERE conversation_id = ?1",
                            rusqlite::params![conversation_id],
                            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                        ) {
                            let mut status_val: serde_json::Value = serde_json::from_str(&task_status_str).unwrap_or_default();
                            // 从 plan_content 获取任务顺序（如有）
                            let ordered_tasks: Vec<String> = if let Some(ref content_str) = plan_content_raw {
                                if let Ok(content) = serde_json::from_str::<serde_json::Value>(content_str) {
                                    content["stages"].as_array().map(|a| a.iter()
                                        .flat_map(|s| s["tasks"].as_array().map(|t| t.iter()).into_iter().flatten())
                                        .filter_map(|t| t["name"].as_str().map(|n| n.to_string()))
                                        .collect()
                                    ).unwrap_or_default()
                                } else { vec![] }
                            } else { vec![] };

                            // 获取 task_status 对象（新格式），或直接使用整个 task_status（旧格式）
                            let empty_map = &mut serde_json::Map::new();
                            let status_obj: &mut serde_json::Map<String, serde_json::Value>;
                            if let Some(o) = status_val.get_mut("task_status").and_then(|s| s.as_object_mut()) {
                                status_obj = o;
                            } else if let Some(o) = status_val.as_object_mut() {
                                status_obj = o;
                            } else {
                                status_obj = empty_map;
                            }

                            // 按顺序找到第一个非 done 的 task
                            let mut target: Option<String> = None;
                            for tname in &ordered_tasks {
                                let cur = status_obj.get(tname.as_str())
                                    .and_then(|s| s.as_str()).unwrap_or("pending");
                                if cur != "done" {
                                    target = Some(tname.clone());
                                    break;
                                }
                            }
                            if let Some(ref tname) = target {
                                status_obj.insert(tname.clone(), serde_json::json!("done"));
                                tracing::info!("READING task done: {}", tname);
                            }

                            let now = chrono::Utc::now().timestamp();
                            let _ = conn.execute(
                                "UPDATE learning_plans SET task_status = ?1, updated_at = ?2 WHERE conversation_id = ?3",
                                rusqlite::params![status_val.to_string(), now, conversation_id],
                            );

                            // 构建合并 plan 供返回值使用
                            let merged: serde_json::Value = if let Some(ref content_str) = plan_content_raw {
                                if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                                    // 读取最新状态（克隆数据避免 borrow 冲突）
                                    let status_map_clone = status_val.get("task_status")
                                        .and_then(|s| s.as_object())
                                        .or_else(|| status_val.as_object())
                                        .cloned()
                                        .unwrap_or_default();
                                    if let Some(stages) = content.get_mut("stages").and_then(|s| s.as_array_mut()) {
                                        for stage in stages {
                                            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                                                for task in tasks {
                                                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                                        let st = status_map_clone.get(name)
                                                            .and_then(|s| s.as_str()).unwrap_or("pending");
                                                        task["status"] = serde_json::json!(st);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    content
                                } else { serde_json::Value::Null }
                            } else { serde_json::Value::Null };
                            task_status = Some(merged);
                        }
                    }
                }
            }
        }
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

    // 检查是否已有学习计划（防止重复创建）
    let existing_plan: Option<String> = conn.query_row(
        "SELECT id FROM learning_plans WHERE conversation_id = ?1 AND mode != 'deleted' LIMIT 1",
        rusqlite::params![conversation_id],
        |row| row.get(0),
    ).ok();

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
    if let Some(plan_obj) = plan.as_object_mut() {
        if let Some(stages) = plan_obj.get_mut("stages").and_then(|s| s.as_array_mut()) {
            for (s_idx, stage) in stages.iter_mut().enumerate() {
                if stage.get("sort").is_none() {
                    stage["sort"] = serde_json::json!(s_idx);
                }
                if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                    for (t_idx, task) in tasks.iter_mut().enumerate() {
                        if task.get("sort").is_none() {
                            task["sort"] = serde_json::json!(t_idx);
                        }
                        if task.get("task_key").is_none() {
                            let tname = task.get("name").and_then(|n| n.as_str()).unwrap_or("");
                            if !tname.is_empty() {
                                task["task_key"] = serde_json::json!(tname);
                            } else {
                                task["task_key"] = serde_json::json!(format!("s{}_t{}", s_idx, t_idx));
                            }
                        }
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
    // 将 plan 中的 tasks 状态展开为 progress 行
    if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
        // 检测 plan type：K12（有预置模板）vs 对话计划（LLM 生成）
        let is_conversation_plan: bool = conn.query_row(
            "SELECT subject FROM conversations WHERE id = ?1",
            rusqlite::params![conversation_id],
            |row| row.get::<_, Option<String>>(0),
        ).ok().flatten().is_none();

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
                    "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, domain, plan_content, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    rusqlite::params![cp1_id, user_id, conversation_id, goal, domain, plan_content_str, now_ts, now_ts],
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
            // K12: 使用 subject_key + "_plan" 作为统一 plan_id
            let subj: String = conn.query_row(
                "SELECT COALESCE(subject, 'general') FROM conversations WHERE id = ?1",
                rusqlite::params![conversation_id],
                |row| row.get(0),
            ).unwrap_or_default();
            let subj_key = if subj.is_empty() { "general" } else { &subj };
            format!("{}_plan", subj_key)
        };

        // 展开 tasks 写入 user_plan_progress
        if !progress_plan_id.is_empty() {
            // 删除旧的 progress 行（幂等更新）
            let _ = conn.execute(
                "DELETE FROM user_plan_progress WHERE plan_id = ?1",
                rusqlite::params![progress_plan_id],
            );
            for (s_idx, stage) in stages.iter().enumerate() {
                if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                    for (t_idx, task) in tasks.iter().enumerate() {
                        let task_key = task.get("task_key").and_then(|k| k.as_str())
                            .unwrap_or("");
                        let task_name = task.get("name").and_then(|n| n.as_str())
                            .unwrap_or("");
                        let status = task.get("status").and_then(|s| s.as_str())
                            .unwrap_or("pending");
                        // 优先用 task_key，其次用 task_name，都没有用位置序号
                        let final_key = if !task_key.is_empty() { task_key.to_string() }
                            else if !task_name.is_empty() { task_name.to_string() }
                            else { format!("s{}_t{}", s_idx, t_idx) };
                        let progress_id = uuid::Uuid::new_v4().to_string();
                        let _ = conn.execute(
                            "INSERT OR REPLACE INTO user_plan_progress (id, user_id, plan_type, plan_id, task_key, status, updated_at)
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                            rusqlite::params![progress_id, user_id, if is_conversation_plan { "conversation" } else { "k12" },
                                progress_plan_id, final_key, status, now_ts],
                        );
                    }
                }
            }
        }
    }

    // ── 旧写路径（learning_plans 仍保留，供 legacy 回退和 k12_quiz 等模块使用）─
    if let Some(existing_id) = existing_plan {
        if let Err(e) = conn.execute(
            "UPDATE learning_plans SET goal=?1, plan_content=?2, task_status=?3, domain=?4, updated_at=?5 WHERE id=?6",
            rusqlite::params![goal, plan_content_str, task_status_str, domain, now, existing_id],
        ) {
            tracing::error!("Learning plan update failed: {} (plan_id={})", e, existing_id);
        } else {
            tracing::debug!("Learning plan updated: {}", existing_id);
        }
    } else {
        let id = uuid::Uuid::new_v4().to_string();
        if let Err(e) = conn.execute(
            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, task_status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?8, ?8)",
            rusqlite::params![id, user_id, conversation_id, goal, domain, plan.to_string(), task_status_str, now],
        ) {
            tracing::error!("Learning plan insert failed: {} (user={}, conv={}, goal={})", e, user_id, conversation_id, goal);
        } else {
            tracing::info!("Learning plan created: {} for user {} (goal: {}, conv: {})", id, user_id, goal, conversation_id);
        }
    }
}

/// 应用计划更新（非新建模式：completed_concepts, task_complete 等）
///
/// 返回更新后的完整 plan JSON，供调用方做成就检测
fn apply_plan_mutations(
    conn: &rusqlite::Connection,
    conversation_id: &str,
    update: &serde_json::Value,
) -> Option<serde_json::Value> {
    let plan_row: Option<(String, String, Option<String>)> = conn.query_row(
        "SELECT id, task_status, plan_content FROM learning_plans WHERE conversation_id = ?1 AND (mode = 'structured' OR mode = 'reading') ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        )),
    ).ok();

    let (plan_id, task_status_str, plan_content_raw) = plan_row?;
    let status_val: serde_json::Value = serde_json::from_str(&task_status_str).ok()?;

    // 合并 plan_content（结构）+ task_status（状态）→ 完整 plan
    let plan_content_str = plan_content_raw?;
    let mut plan = serde_json::from_str::<serde_json::Value>(&plan_content_str).ok()?;
    // 注入已保存的完成概念
    if let Some(concepts) = status_val.get("completed_concepts") {
        plan["completed_concepts"] = concepts.clone();
    }
    // 注入 task_status 到每个 task（plan_content 的 task 没有 status 字段）
    if let (Some(stages), Some(status_obj)) = (
        plan.get_mut("stages").and_then(|s| s.as_array_mut()),
        status_val.get("task_status").and_then(|s| s.as_object()),
    ) {
        for stage in stages {
            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                for task in tasks {
                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                        let st = status_obj.get(name)
                            .and_then(|s| s.as_str())
                            .unwrap_or("pending");
                        task["status"] = serde_json::json!(st);
                    }
                }
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
                                        eprintln!("[CP2 BLOCKED] sub_steps incomplete: teach={}, examples={}, quiz={}, task='{}'", teach, examples, quiz, task.get("name").and_then(|n| n.as_str()).unwrap_or("?"));
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
                                if let Some(next) = update.get("next_stage_suggestion")
                                    .and_then(|v| v.as_str())
                                {
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
                                                break;
                                            }
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

    // 持久化更新后的 plan — 同时同步 plan_content（完整结构）和 task_status（状态快照）
    let now = chrono::Utc::now().timestamp();
    let task_status = extract_task_status(&plan);
    let mut status_update = serde_json::json!({"task_status": task_status});
    if let Some(concepts) = plan.get("completed_concepts") {
        status_update["completed_concepts"] = concepts.clone();
    }

    // 从 in-memory plan 重建 plan_content（保留 stages 结构及更新后的 status）
    let plan_content = serde_json::json!({
        "stages": plan.get("stages"),
        "completed_concepts": plan.get("completed_concepts"),
    });

    if let Err(e) = conn.execute(
        "UPDATE learning_plans SET plan_content = ?1, task_status = ?2, updated_at = ?3 WHERE id = ?4",
        rusqlite::params![plan_content.to_string(), status_update.to_string(), now, plan_id],
    ) {
        tracing::error!("Plan mutation DB write failed: {} (plan_id={})", e, plan_id);
        return None;
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
pub fn check_revert_signals(user_message: &str) -> bool {
    let signals = [
        "回退", "退回去", "还没学会", "没学会", "不理解",
        "不懂", "没懂", "跳太快", "跳得太快", "太快了",
        "进度错了", "进度不对", "进度有问题", "状态错了",
        "标记错了", "超前", "还没掌握", "没掌握",
        "重新学", "再学一遍", "倒回去",
    ];
    let msg_lower = user_message.to_lowercase();
    signals.iter().any(|s| msg_lower.contains(s))
}

/// 自动回退计划（代码层兜底）。
/// 当 LLM 未能处理回退请求时，由调用方直接调用此函数。
pub fn auto_revert(conn: &rusqlite::Connection, conversation_id: &str) -> Option<serde_json::Value> {
    let plan_row: Option<(String, String, Option<String>)> = conn.query_row(
        "SELECT id, task_status, plan_content FROM learning_plans WHERE conversation_id = ?1 AND (mode = 'structured' OR mode = 'reading') ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        )),
    ).ok();

    let (plan_id, task_status_str, plan_content_raw) = plan_row?;
    let status_val: serde_json::Value = serde_json::from_str(&task_status_str).ok()?;
    let plan_content_str = plan_content_raw?; // 迁移后不允许 NULL
    let mut plan = serde_json::from_str::<serde_json::Value>(&plan_content_str).ok()?;

    // 注入状态到 stages
    let smap = status_val.get("task_status")
        .and_then(|s| s.as_object())
        .or_else(|| status_val.as_object());
    if let (Some(status_map), Some(stages)) = (smap, plan["stages"].as_array_mut()) {
        for stage in stages {
            if let Some(tasks) = stage["tasks"].as_array_mut() {
                for task in tasks {
                    if let Some(name) = task["name"].as_str() {
                        let s = status_map.get(name).and_then(|v| v.as_str()).unwrap_or("pending");
                        task["status"] = serde_json::json!(s);
                    }
                }
            }
        }
    }

    let changed = if let Some(stages) = plan["stages"].as_array_mut() {
        let mut modified = false;
        for stage in stages.iter_mut() {
            if stage["status"] == "in_progress" {
                if let Some(tasks) = stage["tasks"].as_array_mut() {
                    for i in 0..tasks.len() {
                        if tasks[i]["status"] == "in_progress" {
                            tasks[i]["status"] = serde_json::json!("pending");
                            // 恢复上一个 done 任务
                            if i > 0 {
                                for j in (0..i).rev() {
                                    if tasks[j]["status"] == "done" {
                                        tasks[j]["status"] = serde_json::json!("in_progress");
                                        break;
                                    }
                                }
                            }
                            modified = true;
                            break;
                        }
                    }
                }
                if modified { break; }
            }
        }
        modified
    } else {
        false
    };

    if !changed {
        return None;
    }

    let now = chrono::Utc::now().timestamp();
    let task_status = extract_task_status(&plan);
    let status_update = serde_json::json!({"task_status": task_status});
    if let Err(e) = conn.execute(
        "UPDATE learning_plans SET task_status = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![status_update.to_string(), now, plan_id],
    ) {
        tracing::error!("Auto-revert DB write failed: {} (plan_id={})", e, plan_id);
        return None;
    }

    tracing::info!("Auto-revert applied for conversation {}", conversation_id);
    Some(plan)
}

// ════════════════════════════════════════════
// Coldpath 2：自动推进评估
// ════════════════════════════════════════════

/// 每 5 轮对话后由 ws.rs 调用，分析最近对话历史判断学生是否应推进到下一任务。
/// 不修改任何数据，只返回评估结论。调用方负责注入标签和执行更新。
pub async fn auto_advance_check(
    caller: &mut chat_engine::llm_caller::LlmCaller,
    recent_history: &[(String, String)],  // (role, content) 最近 3 轮
    task_name: &str,
    task_focus: &str,
    mode: &str,
) -> (bool, String) {
    let dialogue: Vec<String> = recent_history.iter()
        .map(|(role, content)| {
            let label = if role == "user" { "学生" } else { "教师" };
            format!("{}: {}", label, content)
        })
        .collect();
    let dialogue_text = dialogue.join("\n");

    let system = if mode == "reading" {
        "你是一位教学进度分析师。你的任务是分析教师的最后几轮回复，判断教师是否已经完成了当前任务的教学。\n\
         \n\
         判断依据（满足任一即应推进）：\n\
         - 学生能用具体语言内容展示理解（不只是说“我懂了”）\n\
         - 教师自然地引出了下一个任务或内容（如「接下来我们学习」、「下一篇课文正等着你」）\n\
         - 教师做了完整的教学总结并布置了新的内容\n\
         - 教师的回复中暗示当前任务已结束（总结性陈述+新的学习指引）\n\
         \n\
         如果学生展示的深度足够推进到下一课，回复 JSON：{\"should_advance\": true, \"reason\": \"理由\"}\n\
         如果学生还未能掌握，回复 JSON：{\"should_advance\": false, \"reason\": \"理由\"}\n\
         只输出 JSON，不要其他内容。"
    } else {
        "你是一位教学进度分析师。你的任务是分析教师的最后几轮回复，判断教师是否已经完成了当前任务的教学。\n\
         \n\
         判断依据（满足任一即应推进）：\n\
         - 教师明确说恭喜或完成或掌握了或学会了\n\
         - 教师自然地引出了下一个知识点或任务\n\
         - 教师做了完整的教学总结并布置了新的学习内容\n\
         \n\
         如果学生已掌握当前任务，回复 JSON：{\"should_advance\": true, \"reason\": \"理由\"}\n\
         如果还未掌握，回复 JSON：{\"should_advance\": false, \"reason\": \"理由\"}\n\
         只输出 JSON，不要其他内容。"
    };

    let user_prompt = format!(
        "当前任务：{}（教学点：{}）\n\n最近对话：\n{}",
        task_name, task_focus, dialogue_text
    );

    match caller.generate(system, &user_prompt).await {
        Ok(reply) => {
            if let Some(start) = reply.find('{') {
                if let Some(end) = reply[start..].find('}') {
                    let json_str = &reply[start..=start + end];
                    if let Ok(judgment) = serde_json::from_str::<serde_json::Value>(json_str) {
                        let advance = judgment.get("should_advance")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        let reason = judgment.get("reason")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        return (advance, reason);
                    }
                }
            }
            (false, "评估回复解析失败".to_string())
        }
        Err(e) => {
            tracing::error!("auto_advance_check: LLM call failed: {:?}", e);
            (false, format!("LLM 调用失败: {:?}", e))
        }
    }
}

/// 获取课文阅读模式的当前任务（名称 + focus）
/// 从 plan_content 中找第一个状态非 done 的 task
fn get_current_reading_task(task_status: &serde_json::Value, plan_content_raw: &Option<String>) -> Option<(String, String)> {
    // 从 plan_content 取任务顺序
    let content_str = plan_content_raw.as_ref()?;
    let content: serde_json::Value = serde_json::from_str(content_str).ok()?;
    let stages = content.get("stages")?.as_array()?;

    // 从 task_status 取 task_status
    let task_status = task_status.get("task_status")
        .and_then(|s| s.as_object())
        .or_else(|| task_status.as_object())?;

    for stage in stages {
        let tasks = stage.get("tasks")?.as_array()?;
        for task in tasks {
            let name = task.get("name")?.as_str()?;
            let status = task_status.get(name).and_then(|s| s.as_str()).unwrap_or("pending");
            if status != "done" {
                let focus = task.get("focus").and_then(|s| s.as_str()).unwrap_or("");
                return Some((name.to_string(), focus.to_string()));
            }
        }
    }
    None
}

// ════════════════════════════════════════════
// 共享工具函数（REST + WS 共用）
// ════════════════════════════════════════════

/// 构建学习计划上下文文本（注入 LLM 对话 system/user prompt）
///
/// 返回 (mode, plan_context):
/// - mode: `"structured"` 或 `"free"`，调用方据此选择 system_prompt
/// - plan_context: 格式化的 Markdown 上下文（FREE 状态为空字符串）
///
/// 这是 routes.rs context 构建逻辑的唯一权威来源。
/// 测试应调用此函数而非自行复制逻辑。
pub fn build_plan_context(conn: &rusqlite::Connection, conversation_id: &str) -> (String, String, String) {
    // ── V2.1 新路径：优先从 plan_templates + user_plan_progress 或 conversation_plans 读取 ──
    // 先检查 conversation 是否有 subject（K12 / Reading 标志）
    let (conv_subject, conv_grade): (Option<String>, Option<String>) = conn.query_row(
        "SELECT subject, grade_band FROM conversations WHERE id = ?1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((None, None));

    // 尝试从 plan_templates 读取（K12/Reading 路径）
    if let (Some(ref subject), Some(ref grade)) = (conv_subject, conv_grade) {
        let subject_key = if subject.is_empty() { "general" } else { subject.as_str() };

        if let Ok((goal, plan_content_str)) = conn.query_row(
            "SELECT goal, plan_content FROM plan_templates WHERE subject_key = ?1 AND grade_band = ?2 LIMIT 1",
            rusqlite::params![subject_key, grade],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        ) {
            // 从 user_plan_progress 读取进度
            let progress_rows: Vec<(String, String)> = {
                let mut stmt = conn.prepare(
                    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
                ).unwrap();
                stmt.query_map(rusqlite::params![format!("{}_plan", subject_key)], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).unwrap().filter_map(|r| r.ok()).collect()
            };

            // 合并进度到 plan_content stages
            let mut merged: serde_json::Value = serde_json::from_str(&plan_content_str).unwrap_or_default();
            let progress_map: std::collections::HashMap<String, String> = progress_rows.into_iter().collect();

            if let Some(stages) = merged.get_mut("stages").and_then(|s| s.as_array_mut()) {
                for stage in stages {
                    if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                        for task in tasks {
                            let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                            let status = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                            task["status"] = serde_json::json!(status);
                        }
                    }
                }
            }

            // K12/Reading 模式检测
            let mode = if subject == "reading" || subject == "chinese" { "reading" } else { "structured" };
            let pipeline_domain: String = merged.get("pipeline_domain")
                .and_then(|d| d.as_str())
                .or_else(|| merged.get("domain").and_then(|d| d.as_str()))
                .unwrap_or(subject_key)
                .to_string();

            let ctx = build_context_text(&merged, &goal, mode);
            return (pipeline_domain, mode.to_string(), ctx);
        }
    }

    // 尝试从 conversation_plans 读取（对话计划路径）
    if let Ok((goal, plan_content_str)) = conn.query_row(
        "SELECT goal, plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
    ) {
        let plan_content = plan_content_str.unwrap_or_default();
        let mut merged: serde_json::Value = serde_json::from_str(&plan_content).unwrap_or_default();

        // 从 user_plan_progress 读取进度
        let cp1_plan_id: String = conn.query_row(
            "SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![conversation_id],
            |row| row.get(0),
        ).unwrap_or_default();

        if !cp1_plan_id.is_empty() {
            let progress_rows: Vec<(String, String)> = {
                let mut stmt = conn.prepare(
                    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
                ).unwrap();
                stmt.query_map(rusqlite::params![cp1_plan_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).unwrap().filter_map(|r| r.ok()).collect()
            };
            let progress_map: std::collections::HashMap<String, String> = progress_rows.into_iter().collect();
            if let Some(stages) = merged.get_mut("stages").and_then(|s| s.as_array_mut()) {
                for stage in stages {
                    if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                        for task in tasks {
                            let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                            let status = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                            task["status"] = serde_json::json!(status);
                        }
                    }
                }
            }
        }

        let pipeline_domain: String = merged.get("pipeline_domain")
            .and_then(|d| d.as_str())
            .or_else(|| merged.get("domain").and_then(|d| d.as_str()))
            .unwrap_or("")
            .to_string();

        let ctx = build_context_text(&merged, &goal, "structured");
        return (pipeline_domain, "structured".to_string(), ctx);
    }

    // ── 旧路径：从 learning_plans 读取（legacy 兜底） ──
    let plan_row = conn.query_row(
        "SELECT mode, goal, task_status, plan_content, domain FROM learning_plans WHERE conversation_id = ?1 AND (mode = 'structured' OR mode = 'reading') ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,  // task_status 可能 NULL（旧数据无此列）
            row.get::<_, Option<String>>(3)?,
            row.get::<_, String>(4)?,
        )),
    ).ok().and_then(|(mode, goal, task_status_opt, plan_content, domain)| {
        let task_status = task_status_opt.unwrap_or_default();
        mode.map(|m| (m, goal, task_status, plan_content, domain))
    });

    match plan_row {
        Some((mode, goal, task_status, plan_content_raw, _domain)) if mode == "structured" || mode == "reading" => {
            // 合并 content（plan_content / loader）与 status（task_status）
            let status_val: serde_json::Value = serde_json::from_str(&task_status).unwrap_or_default();
            let task_status = status_val.as_object()
                .and_then(|o| o.get("task_status"))
                .or(Some(&status_val)); // 兼容直接存 map 的格式

            let mut merged = if let Some(ref content_str) = plan_content_raw {
                // plan_content 存在（自由探索模式或已有 reading plan 缓存）
                serde_json::from_str::<serde_json::Value>(content_str).unwrap_or_default()
            } else if mode == "reading" {
                // 课文阅读：从 reading_loader 获取
                let grade = conn.query_row(
                    "SELECT grade_band FROM conversations WHERE id = ?1",
                    rusqlite::params![conversation_id],
                    |row| row.get::<_, String>(0),
                ).unwrap_or_default();
                crate::reading_loader::get_plan_content(&_domain, &grade)
                    .unwrap_or_default()
            } else {
                // K12 结构化：从 curriculum_loader 获取（暂缺，用空 plan）
                serde_json::Value::Null
            };

            // 合并状态到 stages
            if let (Some(stages), Some(status_obj)) = (
                merged.get_mut("stages").and_then(|s| s.as_array_mut()),
                task_status.and_then(|s| s.as_object()),
            ) {
                for stage in stages {
                    if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                        for task in tasks {
                            if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                let status = status_obj.get(name)
                                    .and_then(|s| s.as_str())
                                    .unwrap_or("pending");
                                task["status"] = serde_json::json!(status);
                            }
                        }
                    }
                }
            }

            let pipeline_domain: String = merged.get("pipeline_domain")
                .and_then(|d| d.as_str())
                .or_else(|| merged.get("domain").and_then(|d| d.as_str()))
                .unwrap_or("")
                .to_string();

            let mut ctx = format!("\n\n### 学习计划\n长期目标: {}", goal);
            if mode == "reading" {
                // Reading 模式：使用 reading_loader 构建上下文（只取第一个未完成 task）
                // 同时查找下一课名，追加在末尾，避免 CP2 未及时更新时 teacher 不知道往哪走
                if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
                    let mut found_current = false;
                    let mut next_task_name: Option<String> = None;
                    'outer: for stage in stages {
                        if let Some(tasks) = stage["tasks"].as_array() {
                            for task in tasks {
                                let tstatus = task["status"].as_str().unwrap_or("pending");
                                let tname = task["name"].as_str().unwrap_or("");
                                if tstatus != "done" {
                                    if !found_current {
                                        // 第一个未完成 → 当前任务，注入全文
                                        found_current = true;
                                        let reading_ctx = crate::reading_loader::build_reading_context(&merged, tname);
                                        ctx.push_str(&reading_ctx);
                                    } else {
                                        // 第二个未完成 → 下一课，只记名字
                                        next_task_name = Some(tname.to_string());
                                        break 'outer;
                                    }
                                }
                            }
                        }
                    }
                    if let Some(ref next) = next_task_name {
                        ctx.push_str(&format!("\n\n### 下一课\n{}", next));
                    }
                }
                (pipeline_domain, "reading".to_string(), ctx)
            } else {
                // Structured 模式：列出当前阶段 task 名称 + 下一阶段名
                if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
                    let mut found_current = false;
                    let mut next_stage_name: Option<String> = None;
                    let mut current_task: Option<&serde_json::Value> = None;
                    for stage in stages {
                        let name = stage["name"].as_str().unwrap_or("");
                        let status = stage["status"].as_str().unwrap_or("pending");
                        if status == "in_progress" || status == "pending" {
                            if !found_current {
                                found_current = true;
                                ctx.push_str(&format!("\n当前阶段: {} ({})", name, status));
                                if let Some(tasks) = stage["tasks"].as_array() {
                                    for task in tasks {
                                        let tname = task["name"].as_str().unwrap_or("");
                                        let tstatus = task["status"].as_str().unwrap_or("pending");
                                        ctx.push_str(&format!("\n  - {}: {}", tname, tstatus));
                                        // 当前 in_progress 的任务用于查询预置卡 fronts
                                        if tstatus == "in_progress" && current_task.is_none() {
                                            current_task = Some(task);
                                        }
                                    }
                                }
                            } else {
                                next_stage_name = Some(name.to_string());
                                break;
                            }
                        }
                    }
                    // 追加当前 task 预置卡 fronts（预置卡去重 + Teacher 参考）
                    if let Some(task) = current_task {
                        let card_fronts = get_prebuilt_card_fronts(
                            conn, conversation_id, task,
                        );
                        if !card_fronts.is_empty() {
                            ctx.push_str(&format!("\n  当前任务已绑定的卡片: {}", card_fronts.join("、")));
                        }
                    }
                    if let Some(ref next) = next_stage_name {
                        ctx.push_str(&format!("\n下一阶段: {}", next));
                    }
                }
                (pipeline_domain, "structured".to_string(), ctx)
            }
        }
        _ => ("".to_string(), "free".to_string(), String::new()),
    }
}

/// 从 merged plan JSON（含 status 已合并的 stages）构建 LLM 上下文文本
fn build_context_text(merged: &serde_json::Value, goal: &str, mode: &str) -> String {
    let mut ctx = format!("\n\n### 学习计划\n长期目标: {}", goal);
    let mut current_task_name: Option<String> = None;
    let mut current_stage_name: Option<String> = None;

    if mode == "reading" {
        if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
            let mut found_current = false;
            let mut next_task_name: Option<String> = None;
            'outer: for stage in stages {
                if let Some(tasks) = stage["tasks"].as_array() {
                    for task in tasks {
                        let tstatus = task["status"].as_str().unwrap_or("pending");
                        let tname = task["name"].as_str().unwrap_or("");
                        if tstatus != "done" {
                            if !found_current {
                                found_current = true;
                                current_task_name = Some(tname.to_string());
                                current_stage_name = stage["name"].as_str().map(|s| s.to_string());
                                let reading_ctx = crate::reading_loader::build_reading_context(merged, tname);
                                ctx.push_str(&reading_ctx);
                            } else {
                                next_task_name = Some(tname.to_string());
                                break 'outer;
                            }
                        }
                    }
                }
            }
            if let Some(ref next) = next_task_name {
                ctx.push_str(&format!("\n\n### 下一课\n{}", next));
            }
        }
    } else {
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

    ctx
}

/// 从 task JSON 中提取预置卡 fronts（用于注入 build_plan_context）
/// 查询 curriculum_loader / reading_loader 中 task 关联的卡片 fronts。
/// 不依赖 unlock_next_cards 是否已执行（直接查预置卡源数据）。
fn get_prebuilt_card_fronts(
    conn: &rusqlite::Connection,
    conversation_id: &str,
    task: &serde_json::Value,
) -> Vec<String> {
    let mut fronts: Vec<String> = Vec::new();

    // 获取 conversation 的 subject 和 grade_band（用于 curriculum_loader 查询）
    let (subject, grade_band): (String, String) = conn.query_row(
        "SELECT COALESCE(subject, ''), COALESCE(grade_band, '') FROM conversations WHERE id = ?1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or_default();

    // ── 管道 A: 词卡 (vocab_card_ids) ──
    let vocab_ids: Vec<&str> = task.get("vocab_card_ids")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    if !vocab_ids.is_empty() && !subject.is_empty() && !grade_band.is_empty() {
        if let Some(card_list) = crate::curriculum_loader::get_cards(&subject, &grade_band) {
            let vocab_set: std::collections::HashSet<&str> = vocab_ids.iter().cloned().collect();
            for card in card_list {
                if vocab_set.contains(card.id.as_str()) {
                    fronts.push(card.front.clone());
                }
            }
        }
    }

    // ── 管道 B: 课文卡 (reading_card_id) ──
    let reading_card_id = task.get("reading_card_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if !reading_card_id.is_empty() {
        if let Some(card) = crate::reading_loader::get_card(reading_card_id) {
            fronts.push(card.front.clone());
        }
    }

    // ── 管道 C: 概念卡 / K12 金牌卡 (gold_cr_ids) ──
    let gold_ids: Vec<&str> = task.get("gold_cr_ids")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    if !gold_ids.is_empty() && !subject.is_empty() && !grade_band.is_empty() {
        if let Some(card_list) = crate::curriculum_loader::get_cards(&subject, &grade_band) {
            for card in card_list {
                if card.gold_cr_ids.iter().any(|g| gold_ids.contains(&g.as_str())) {
                    fronts.push(card.front.clone());
                }
            }
        }
    }

    fronts
}

/// 构建计划分析 prompt（用于 ColdPath 2）
/// pass_rate_info: 可选的客观通过率描述文本（如 "客观完成率：当前任务通过率 75%（需 ≥ 80%）"）
pub fn build_plan_analysis_prompt(
    conversation_history: &[(String, String)],
    task_status: &serde_json::Value,
    pass_rate_info: Option<&str>,
) -> String {
    let dialogue: Vec<String> = conversation_history.iter()
        .map(|(role, content)| {
            let label = if role == "user" { "学生" } else { "教师" };
            format!("{}: {}", label, content)
        })
        .collect();
    let dialogue_text = dialogue.join("\n");

    let stages_text: String = if let Some(stages) = task_status.get("stages").and_then(|v| v.as_array()) {
        stages.iter().map(|s| {
            let name = s["name"].as_str().unwrap_or("");
            let status = s["status"].as_str().unwrap_or("pending");
            let tasks: Vec<String> = s.get("tasks").and_then(|t| t.as_array()).map(|arr| {
                arr.iter().map(|t| {
                    format!("    {}: {}", t["name"].as_str().unwrap_or(""), t["status"].as_str().unwrap_or("pending"))
                }).collect()
            }).unwrap_or_default();
            format!("- {} ({}){}", name, status,
                if tasks.is_empty() { String::new() } else { format!("\n{}", tasks.join("\n")) })
        }).collect::<Vec<_>>().join("\n")
    } else { String::new() };

    let goal = task_status.get("goal").and_then(|v| v.as_str()).unwrap_or("");
    let pass_rate_line = pass_rate_info.map(|p| format!("\n{}\n", p)).unwrap_or_default();
    let tpl = chat_engine::prompt_loader::get_plan("general");
    tpl.analysis.replace("{goal}", goal)
        .replace("{stages_text}", &stages_text)
        .replace("{pass_rate_line}", &pass_rate_line)
        .replace("{dialogue_text}", &dialogue_text)
}

/// ColdPath 2: 创建计划 prompt — 无现有计划时使用
/// 与 build_plan_analysis_prompt 物理拆分，职责清晰
/// 模板从 prompts/general/plan-creation.md 加载
pub fn build_plan_creation_prompt(dialogue_text: &str) -> String {
    let tpl_path = {
        let dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
        format!("{}/general/plan-creation.md", dir)
    };
    let tpl = std::fs::read_to_string(&tpl_path).unwrap_or_else(|_| {
        // 降级：硬编码兜底
        let default = r#"根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{dialogue_text}

请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可，如"一元二次方程求解"、"Python入门"）
- domain: 学科（general/math/language/chemistry/biology/physics/history/geography/politics/science/it/pe/art/labor 之一）
- stages: 阶段数组，每个阶段包含 name、status（in_progress/pending/completed）、tasks 数组
- 每项 task 包含 name、status、description
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

确保计划包含 3-5 个阶段，每个阶段 2-3 个任务，覆盖完整的学习路径。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}
"#;
        default.to_string()
    });
    tpl.replace("{dialogue_text}", dialogue_text)
}

/// ColdPath 2: 分析对话进度，更新学习计划（如无计划则自动创建）
/// 内部自行管理 DB 连接，不持有跨 .await 的引用（兼容 tokio::spawn）
pub async fn analyze_plan_progress(
    conversation_id: &str,
    user_id: &str,
    caller: &mut chat_engine::llm_caller::LlmCaller,
) -> bool {
    let conv_id = conversation_id.to_string();
    let uid = user_id.to_string();

    // 第一步：读取数据
    let (relevant, plan_row) = {
        let conn = crate::db_pool::get_conn();
        let history_raw: Vec<(String, String)> = {
            let mut stmt = match conn.prepare(
                "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at DESC LIMIT 20"
            ) {
                Ok(s) => s,
                Err(_) => return false,
            };
            let mut turns: Vec<(String, String)> = stmt.query_map(
                rusqlite::params![conversation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            ).unwrap().filter_map(|r| r.ok()).collect();
            turns.reverse();
            turns
        };

        let relevant: Vec<(String, String)> = history_raw.into_iter()
            .filter(|(r, _)| r == "user" || r == "assistant")
            .collect();

        if relevant.len() < 2 {
            return false; // 对话太短
        }

        // 检查是否已有计划 — 不限 mode
        let plan_row: Option<(String, Option<String>, Option<String>)> = conn.query_row(
            "SELECT task_status, plan_content, mode FROM learning_plans WHERE conversation_id = ?1 ORDER BY updated_at DESC LIMIT 1",
            rusqlite::params![&conv_id],
            |row| Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
            )),
        ).ok();

        (relevant, plan_row)
    }; // conn 在此释放，后面的 .await 安全

    match plan_row {
        Some((task_status_str, plan_content_raw, mode)) => {
            let task_status: serde_json::Value = match serde_json::from_str(&task_status_str) {
                Ok(v) => v,
                Err(_) => return false,
            };

            // 根据 mode 选择评估方式
            let is_reading = mode.as_deref() == Some("reading");

            if is_reading {
                // 课文阅读模式：使用 auto_advance_check
                let recent: Vec<(String, String)> = relevant.into_iter().rev().take(6).collect();
                let current_task = get_current_reading_task(&task_status, &plan_content_raw);
                let (task_name, task_focus) = match current_task {
                    Some((n, f)) => (n, f),
                    None => return false,
                };
                let mut cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
                    &std::env::var("DEEPSEEK_API_KEY").unwrap_or_default()
                );
                cfg.temperature = 0.0;
                let mut advance_caller = chat_engine::llm_caller::LlmCaller::new(cfg);
                let (should_advance, reason) = auto_advance_check(
                    &mut advance_caller, &recent, &task_name, &task_focus, "reading",
                ).await;
                if should_advance {
                    let conn = crate::db_pool::get_conn();
                    let tag = "<reading_update>{\"complete_current_task\": true}</reading_update>".to_string();
                    let result = handle_plan_update(&conn, &tag, &conv_id, &uid);
                    // reading 模式也触发卡片渐进解锁
                    if result.plan_updated {
                        if let Some(ref updated_plan) = result.task_status {
                            unlock_next_cards(&conn, &conv_id, &uid, updated_plan);
                        }
                    }
                    tracing::info!("Reading auto-advance: task={}, reason={}, updated={}",
                        task_name, reason, result.plan_updated);
                    result.plan_updated
                } else {
                    false
                }
            } else {
            // 合并 plan_content + task_status(task_status) → 全量 plan（供分析使用）
            let merged_plan: serde_json::Value = if let Some(ref content_str) = plan_content_raw {
                if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                    let smap = task_status.get("task_status")
                        .and_then(|s| s.as_object())
                        .or_else(|| task_status.as_object());
                    if let (Some(status_map), Some(stages)) = (smap, content.get_mut("stages").and_then(|s| s.as_array_mut())) {
                        for stage in stages {
                            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                                for task in tasks {
                                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                        let st = status_map.get(name).and_then(|s| s.as_str()).unwrap_or("pending");
                                        task["status"] = serde_json::json!(st);
                                    }
                                }
                            }
                        }
                    }
                    content
                } else { task_status.clone() }
            } else { task_status.clone() };

            // 计算客观通过率，注入 prompt
            let pass_rate_info: Option<String> = {
                let conn = crate::db_pool::get_conn();
                get_current_task_name(&merged_plan).and_then(|task_name| {
                    let total: i64 = conn.query_row(
                        "SELECT COUNT(*) FROM k12_quiz_bank WHERE task_name = ?1",
                        rusqlite::params![&task_name],
                        |row| row.get(0),
                    ).unwrap_or(0);
                    if total == 0 { return None; } // 无题库
                    let correct: i64 = conn.query_row(
                        "SELECT COUNT(*) FROM k12_quiz_attempts
                         WHERE user_id = ?1 AND task_name = ?2 AND attempted_at >= ?3 AND is_correct = 1",
                        rusqlite::params![&uid, &task_name, seven_days_ago()],
                        |row| row.get(0),
                    ).unwrap_or(0);
                    let total_attempts: i64 = conn.query_row(
                        "SELECT COUNT(*) FROM k12_quiz_attempts
                         WHERE user_id = ?1 AND task_name = ?2 AND attempted_at >= ?3",
                        rusqlite::params![&uid, &task_name, seven_days_ago()],
                        |row| row.get(0),
                    ).unwrap_or(0);
                    if total_attempts == 0 {
                        Some(format!("客观完成率：当前任务「{}」有 {} 道题库题目，但尚未完成任何测评。", task_name, total))
                    } else {
                        let pct = (correct as f64 / total_attempts as f64 * 100.0).round() as i64;
                        Some(format!("客观完成率：当前任务「{}」题库通过率为 {}%（{}次正确/{}次作答，需 ≥ 80%）。", task_name, pct, correct, total_attempts))
                    }
                })
            };
            // 合并 plan_content + task_status(task_status) → 全量 plan（供分析使用）
            let merged_plan: serde_json::Value = if let Some(ref content_str) = plan_content_raw {
                if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                    let smap = task_status.get("task_status")
                        .and_then(|s| s.as_object())
                        .or_else(|| task_status.as_object());
                    if let (Some(status_map), Some(stages)) = (smap, content.get_mut("stages").and_then(|s| s.as_array_mut())) {
                        for stage in stages {
                            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                                for task in tasks {
                                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                        let st = status_map.get(name).and_then(|s| s.as_str()).unwrap_or("pending");
                                        task["status"] = serde_json::json!(st);
                                    }
                                }
                            }
                        }
                    }
                    content
                } else { task_status.clone() }
            } else { task_status.clone() };
            let prompt = build_plan_analysis_prompt(&relevant, &merged_plan, pass_rate_info.as_deref());
            match caller.generate("", &prompt).await {
                Ok(response) => {
                    let conn = crate::db_pool::get_conn();
                    // 后处理：客观通过率 >= 80% 则强制标记任务完成
                    let processed = if let Some(task_name) = get_current_task_name(&merged_plan) {
                        if crate::k12_quiz::should_mark_task_complete(&conn, &uid, &task_name) {
                            // 解析 LLM 返回，补上 current_task_complete: true
                            let mut plan_update: serde_json::Value = match serde_json::from_str(&response) {
                                Ok(v) => v,
                                Err(_) => serde_json::json!({"current_task_complete": true}),
                            };
                            if plan_update.get("current_task_complete").and_then(|v| v.as_bool()) != Some(true) {
                                if let Some(obj) = plan_update.as_object_mut() {
                                    obj.insert("current_task_complete".to_string(), serde_json::Value::Bool(true));
                                }
                            }
                            serde_json::to_string(&plan_update).unwrap_or(response)
                        } else {
                            response
                        }
                    } else {
                        response
                    };
                    let result = handle_plan_update(&conn, &format!("<plan_update>{}</plan_update>", processed), &conv_id, &uid);
                    // 卡片渐进解锁：任务完成后解锁下一批卡片
                    // 使用 handle_plan_update 返回的更新后 plan（含 stages + 最新 task_status）
                    if result.plan_updated {
                        if let Some(ref updated_plan) = result.task_status {
                            unlock_next_cards(&conn, &conv_id, &uid, updated_plan);
                        }
                    }
                    result.plan_updated
                }
                Err(_) => false,
            }
        }
    }
    None => {
            // 无计划 → 自动创建新计划
            let dialogue_text: String = relevant.iter()
                .map(|(role, content)| {
                    let label = if role == "user" { "学生" } else { "教师" };
                    format!("{}: {}", label, content)
                })
                .collect::<Vec<_>>()
                .join("\n");

            let prompt = build_plan_creation_prompt(&dialogue_text);

            match caller.generate("", &prompt).await {
                Ok(response) => {
                    let conn = crate::db_pool::get_conn();
                    let result = handle_plan_update(&conn, &format!("<plan_update>{}</plan_update>", response), &conv_id, &uid);
                    result.is_new_plan || result.plan_updated
                }
                Err(_) => false,
            }
        }
    }
}

/// 7 天前的时间戳（RFC 3339），用于题库通过率查询
fn seven_days_ago() -> String {
    (chrono::Utc::now() - chrono::Duration::days(7)).to_rfc3339()
}

/// ❄️ CP2 轻量版：每轮检测，只用 teacher 最后一轮回复
///
/// 调用前提：HotPath 未处理（plan_updated == false）
///
/// 1. 无 plan → 单轮 LLM 分析 teacher 回复是否引入了新学习任务
/// 2. 有 plan → 正则匹配通关信号（支持 🎉 通关！/ **✅ 已完成** / 学习已经完成）
///
/// 通过 handle_plan_update 写入，与 HotPath 共用同一套更新逻辑。
pub async fn analyze_turn_progress(
    conversation_id: &str,
    user_id: &str,
    caller: &mut chat_engine::llm_caller::LlmCaller,
    final_reply: &str,
) -> bool {
    let (has_plan, _mode) = {
        let conn = crate::db_pool::get_conn();
        match conn.query_row(
            "SELECT task_status, mode FROM learning_plans WHERE conversation_id = ?1 ORDER BY updated_at DESC LIMIT 1",
            rusqlite::params![conversation_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        ) {
            Ok((_, mode)) => (true, mode.unwrap_or_default()),
            Err(_) => (false, String::new()),
        }
    };

    if !has_plan {
        // ── 无 plan：先用 final_reply 快速轻量检测是否引入了学习任务 ──
        // 有信号时回退到对话全量历史创建 plan（因 plan 创建需要完整上下文）
        let signal_prompt = chat_engine::prompt_loader::get_plan("general").signal
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

    // ── 有 plan：检测 teacher 是否完成了当前任务 ──

        // ★★ Fast Path: 正则式匹配通关信号（flexible pattern matching）
        // 支持三种格式：
        //   1. 旧格式： "## 🎉 通关！{任务名}"  (带有 🎉 emoji)
        //   2. 新格式： "**{任务名} ✅ 已完成**"  (由 build_context_text 动态注入)
        //   3. 兜底：   "{任务名}学习已经完成"        (兼容旧 prompt)
        let badge_found = {
            let cleaned = final_reply
                .replace('\r', "")
                .replace("##  ", "## ")
                .replace("##\t", "## ");
            // 尝试匹配多种常见变体
            let patterns = [
                "## 🎉 通关！",
                "##🎉通关！",
                "## 🎉通关！",
                "## 🎉 通关!",
                "##🎉通关!",
            ];
            patterns.iter().any(|p| cleaned.contains(p))
                || final_reply.contains("通关！")       // 兜底：只要包含"通关！"
                   && final_reply.contains("##")        // 且是标题格式
                || final_reply.contains("✅ 已完成")     // 新格式：**任务名 ✅ 已完成**
                || final_reply.contains("学习已经完成")  // 兜底：{任务名}学习已经完成（旧 prompt 兼容）
        };

        if badge_found {
            // 从回复中提取任务名：支持三种通关格式
            let task_name: String = {
                // 格式1: "## 🎉 通关！{任务名}" — 从 "通关！" 后取到行尾
                let from_badge = final_reply.split("通关！")
                    .nth(1)
                    .or_else(|| final_reply.split("通关!").nth(1))
                    .and_then(|after| {
                        let trimmed = after.trim();
                        trimmed.lines().next()
                            .map(|s| s.trim().to_string())
                    })
                    .filter(|s| !s.is_empty());
                if let Some(name) = from_badge { name }
                else {
                    // 格式2: "**{任务名} ✅ 已完成**" — 取 ** 之间的内容
                    let from_new = final_reply.split("✅ 已完成").next()
                        .and_then(|before| {
                            before.rsplit("**").nth(1)
                                .or_else(|| before.rsplit("**").next())
                                .map(|s| s.trim().to_string())
                        })
                        .filter(|s| !s.is_empty());
                    if let Some(name) = from_new { name }
                    else {
                        // 格式3: "{任务名}学习已经完成" — 取 "学习已经完成" 前的内容
                        final_reply.split("学习已经完成").next()
                            .map(|s| s.trim().to_string())
                            .unwrap_or_default()
                    }
                }
            };

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
    let (subject, grade_band): (Option<String>, Option<String>) = conn.query_row(
        "SELECT subject, grade_band FROM conversations WHERE id = ?1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((None, None));

    // ── 管道 A: 词卡 (vocab_card_ids) ──
    // 从 compulsory 卡片集中通过 id 匹配导入
    let vocab_ids: Vec<String> = next_task.get("vocab_card_ids")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();

    if !vocab_ids.is_empty() {
        let subj = subject.as_deref().unwrap_or("chinese");  // reading 卡片多为语文/英语，留作默认
        let grade = grade_band.as_deref().unwrap_or("g7-9");
        if let Some(card_list) = crate::curriculum_loader::get_cards(subj, grade) {
            let vocab_id_set: std::collections::HashSet<&str> =
                vocab_ids.iter().map(|s| s.as_str()).collect();
            for card_tmpl in card_list {
                if !vocab_id_set.contains(card_tmpl.id.as_str()) {
                    continue;
                }
                let card_id = format!("vocab_{}", &card_tmpl.id);
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, k12_card_id)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    rusqlite::params![card_id, user_id, subj, card_tmpl.card_type,
                        card_tmpl.front, card_tmpl.back, card_tmpl.source_sentence, conversation_id, now_ts,
                        subj, grade, card_tmpl.id],
                );
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                     VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
                    rusqlite::params![card_id, now_ts],
                );
            }
        }
    }

    // ── 管道 B: 课文卡 (reading_card_id) ──
    let reading_card_id = next_task.get("reading_card_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if !reading_card_id.is_empty() {
        if let Some(card) = crate::reading_loader::get_card(&reading_card_id) {
            let subj = subject.as_deref().unwrap_or("chinese");
            let grade = grade_band.as_deref().unwrap_or("g7-9");
            let card_id = format!("reading_{}", &card.id);
            let _ = conn.execute(
                "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, k12_card_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                rusqlite::params![card_id, user_id, subj, &card.card_type,
                    &card.front, card.back.as_deref().unwrap_or(""), &card.background, conversation_id, now_ts,
                    subj, grade, &card.id],
            );
            let _ = conn.execute(
                "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                 VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
                rusqlite::params![card_id, now_ts],
            );
        }
    }

    // ── 管道 C: 概念卡 / K12 金牌卡 (gold_cr_ids) ──
    let gold_ids: Vec<String> = next_task.get("gold_cr_ids")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();

    if !gold_ids.is_empty() {
        let subj = subject.as_deref().unwrap_or("chinese");
        let grade = grade_band.as_deref().unwrap_or("g7-9");
        if let Some(card_list) = crate::curriculum_loader::get_cards(subj, grade) {
            for card_tmpl in card_list {
                if !card_tmpl.gold_cr_ids.iter().any(|g| gold_ids.contains(g)) {
                    continue;
                }
                let card_id = format!("k12_{}", &card_tmpl.id);
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, k12_card_id)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    rusqlite::params![card_id, user_id, subj, card_tmpl.card_type,
                        card_tmpl.front, card_tmpl.back, card_tmpl.source_sentence, conversation_id, now_ts,
                        subj, grade, card_tmpl.id],
                );
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                     VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
                    rusqlite::params![card_id, now_ts],
                );
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

/// 写入成就（去重）
///
/// 使用 INSERT OR IGNORE + 唯一索引保证原子性，消除 SELECT+INSERT 的 TOCTOU 竞态窗口。
pub fn write_achievement(conn: &rusqlite::Connection, user_id: &str, key: &str, name: &str, icon: &str, tier: &str, source: &str) {
    let now = chrono::Utc::now().timestamp();
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO achievements (id, user_id, achievement_key, name, icon, tier, source, unlocked_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), user_id, key, name, icon, tier, source, now],
    ).unwrap_or(0);
    if inserted > 0 {
        tracing::debug!("Achievement unlocked: {} ({})", key, user_id);
    }
}

/// 检查成就是否已存在
pub fn achievement_exists(conn: &rusqlite::Connection, user_id: &str, key: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM achievements WHERE user_id = ?1 AND achievement_key = ?2",
        rusqlite::params![user_id, key],
        |_| Ok(true),
    ).unwrap_or(false)
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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, task_status TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', NULL, ?, '2024-01-01', '2024-01-01');
        ").unwrap();

        // 初始计划：Task1 in_progress, Task2 pending
        let plan_content = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "in_progress"},
                    {"name": "Task2", "status": "pending"}
                ]
            }],
            "completed_concepts": []
        });
        let task_status_status = json!({"task_status": {"Task1": "in_progress", "Task2": "pending"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, task_status=?2 WHERE id='p1'",
            rusqlite::params![plan_content.to_string(), task_status_status.to_string()]).unwrap();

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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, task_status TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', NULL, ?, '2024-01-01', '2024-01-01');
        ").unwrap();

        // 模拟超前更新后的状态：Task1 done, Task2 in_progress（但用户实际还没学完 Task1）
        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "done"},
                    {"name": "Task2", "status": "in_progress"}
                ]
            }],
            "completed_concepts": ["概念1"]
        });
        let task_status_status = json!({"task_status": {"Task1": "done", "Task2": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, task_status=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), task_status_status.to_string()]).unwrap();

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
    fn test_check_revert_signals() {
        assert!(check_revert_signals("等一下，我还没学会，能回退吗"));
        assert!(check_revert_signals("这个我不理解，需要重新学"));
        assert!(check_revert_signals("跳太快了，进度不对"));
        assert!(check_revert_signals("你标记错了，这部分我还没掌握"));
        assert!(check_revert_signals("我完全没懂，能倒回去吗"));
        assert!(!check_revert_signals("好的，我理解了"));
        assert!(!check_revert_signals("继续下一个"));
        assert!(!check_revert_signals("这个例子很好"));
    }

    #[test]
    fn test_auto_revert() {
        use rusqlite::Connection;
        use serde_json::json;

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, task_status TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', NULL, ?, '2024-01-01', '2024-01-01');
        ").unwrap();

        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "done"},
                    {"name": "Task2", "status": "in_progress"}
                ]
            }],
            "completed_concepts": []
        });
        let task_status_status = json!({"task_status": {"Task1": "done", "Task2": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, task_status=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), task_status_status.to_string()]).unwrap();

        let result = auto_revert(&conn, "c1").expect("auto_revert should succeed");
        let tasks = result["stages"][0]["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["status"], "in_progress", "Task1 should be restored");
        assert_eq!(tasks[1]["status"], "pending", "Task2 should be reverted");
    }

    #[test]
    fn test_sub_steps_block_completion() {
        // 验证子阶段未全部 done 时，current_task_complete 被拒绝
        use rusqlite::Connection;
        use serde_json::json;

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, task_status TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', NULL, ?, '2024-01-01', '2024-01-01');
        ").unwrap();

        // 任务含 sub_steps 但 quiz 未完成
        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [{
                    "name": "Task1", "status": "in_progress",
                    "sub_steps": {"teach": "done", "examples": "done", "quiz": "pending"}
                }]
            }],
            "completed_concepts": []
        });
        let task_status_status = json!({"task_status": {"Task1": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, task_status=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), task_status_status.to_string()]).unwrap();

        // 尝试推进 — 应被拒绝
        let reply = format!("<plan_update>\n{}\n</plan_update>", json!({
            "current_task_complete": true
        }));
        let result = handle_plan_update(&conn, &reply, "c1", "u1");
        assert!(!result.plan_updated, "sub_steps incomplete → should block");

        // 现在完成 quiz
        let reply2 = format!("<plan_update>\n{}\n</plan_update>", json!({
            "task_sub_steps": {"quiz": "done"}
        }));
        let result2 = handle_plan_update(&conn, &reply2, "c1", "u1");
        assert!(result2.plan_updated, "sub_steps update should work");
        let quiz_status = result2.task_status.as_ref().unwrap()["stages"][0]["tasks"][0]["sub_steps"]["quiz"].as_str().unwrap();
        assert_eq!(quiz_status, "done");

        // 现在推进 — 应成功
        let reply3 = format!("<plan_update>\n{}\n</plan_update>", json!({
            "current_task_complete": true
        }));
        let result3 = handle_plan_update(&conn, &reply3, "c1", "u1");
        assert!(result3.plan_updated, "sub_steps all done → should complete");
        assert_eq!(result3.task_status.unwrap()["stages"][0]["tasks"][0]["status"], "done");
    }
}
