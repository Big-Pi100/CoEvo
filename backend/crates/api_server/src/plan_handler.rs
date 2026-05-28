//! 学习计划处理 — WebSocket 和 REST 共用模块
//!
//! 负责:
//!   1. 解析 LLM 回复中的 <plan_update>...</plan_update> XML 标签
//!   2. 创建/更新 learning_plans 表
//!   3. 返回清理后的回复文本

use serde_json::json;

/// 从 plan_json 中找到当前 in_progress 的 task 名称
pub fn get_current_task_name(plan_json: &serde_json::Value) -> Option<String> {
    let stages = plan_json.get("stages").and_then(|v| v.as_array())?;
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
    pub plan_json: Option<serde_json::Value>,
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
    let mut plan_json: Option<serde_json::Value> = None;

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
                        plan_json = Some(update.clone());
                        upsert_learning_plan(conn, user_id, conversation_id, &update);
                        plan_updated = true;
                    } else {
                        if let Some(plan) = apply_plan_mutations(conn, conversation_id, &update) {
                            plan_json = Some(plan);
                            plan_updated = true;
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
                        // 读取 plan_json（task_status 映射）和 plan_content（任务顺序）
                        if let Ok((plan_json_str, plan_content_raw)) = conn.query_row(
                            "SELECT plan_json, plan_content FROM learning_plans WHERE conversation_id = ?1",
                            rusqlite::params![conversation_id],
                            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                        ) {
                            let mut status_val: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap_or_default();
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

                            // 获取 task_status 对象（新格式），或直接使用整个 plan_json（旧格式）
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

                            let now = chrono::Utc::now().to_rfc3339();
                            let _ = conn.execute(
                                "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE conversation_id = ?3",
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
                            plan_json = Some(merged);
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
        plan_json,
    }
}

/// 创建或更新学习计划（新建模式）
fn upsert_learning_plan(
    conn: &rusqlite::Connection,
    user_id: &str,
    conversation_id: &str,
    update: &serde_json::Value,
) {
    let now = chrono::Utc::now().to_rfc3339();
    let goal = update["goal"].as_str().unwrap_or("");
    let mut plan = update.clone();
    // 跟踪 plan_update 次数（用于评估和分析）
    let prev_count = plan.get("plan_update_count").and_then(|v| v.as_u64()).unwrap_or(0);
    plan.as_object_mut().map(|o| {
        o.insert("plan_update_count".to_string(), serde_json::Value::Number((prev_count + 1).into()));
    });
    let _ = plan.as_object_mut().map(|o| {
        o.remove("is_new_plan");
        o.remove("goal");
    });

    // domain = conversation_id，确保每个对话独立拥有学习计划
    // （UNIQUE INDEX 约束 (user_id, domain)，同一用户不同对话各自独立）
    let domain = conversation_id;

    // 检查是否已有学习计划（防止重复创建）
    let existing_plan: Option<String> = conn.query_row(
        "SELECT id FROM learning_plans WHERE conversation_id = ?1 AND mode != 'deleted' LIMIT 1",
        rusqlite::params![conversation_id],
        |row| row.get(0),
    ).ok();

    // 新格式：plan_content=完整结构，plan_json=task_status 映射
    let plan_content_str = plan.to_string();
    let task_status_val = extract_task_status(&plan);
    let plan_json_str = serde_json::json!({"task_status": task_status_val}).to_string();

    if let Some(existing_id) = existing_plan {
        if let Err(e) = conn.execute(
            "UPDATE learning_plans SET goal=?1, plan_content=?2, plan_json=?3, domain=?4, updated_at=?5 WHERE id=?6",
            rusqlite::params![goal, plan_content_str, plan_json_str, domain, now, existing_id],
        ) {
            tracing::error!("Learning plan update failed: {} (plan_id={})", e, existing_id);
        } else {
            tracing::debug!("Learning plan updated: {}", existing_id);
        }
    } else {
        let id = uuid::Uuid::new_v4().to_string();
        if let Err(e) = conn.execute(
            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, plan_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?8, ?8)",
            rusqlite::params![id, user_id, conversation_id, goal, domain, plan.to_string(), plan_json_str, now],
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
        "SELECT id, plan_json, plan_content FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        )),
    ).ok();

    let (plan_id, plan_json_str, plan_content_raw) = plan_row?;
    let status_val: serde_json::Value = serde_json::from_str(&plan_json_str).ok()?;

    // 合并 plan_content（结构）+ plan_json（状态）→ 完整 plan
    let plan_content_str = plan_content_raw?;
    let mut plan = serde_json::from_str::<serde_json::Value>(&plan_content_str).ok()?;
    // 注入已保存的完成概念
    if let Some(concepts) = status_val.get("completed_concepts") {
        plan["completed_concepts"] = concepts.clone();
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
                                        tracing::warn!(
                                            "BLOCKED: current_task_complete=true but sub_steps incomplete. \
                                            teach={}, examples={}, quiz={}",
                                            teach, examples, quiz
                                        );
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
                if stage["status"] == "in_progress" || stage["status"] == "pending" {
                    // 确保阶段是 in_progress（可能从 pending 激活）
                    if stage["status"] == "pending" {
                        stage["status"] = json!("in_progress");
                    }

                    if let Some(tasks) = stage["tasks"].as_array_mut() {
                        // 先找 in_progress 的任务；如果没有，激活第一个 pending 任务
                        let mut task_found = false;
                        for task in tasks.iter_mut() {
                            if task["status"] == "in_progress" {
                                task["status"] = json!("done");
                                task_found = true;
                                break;
                            }
                        }
                        if !task_found {
                            // 没有 in_progress 任务 → 激活第一个 pending 任务并标记完成
                            for task in tasks.iter_mut() {
                                if task["status"] == "pending" {
                                    task["status"] = json!("done");
                                    task_found = true;
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
                            } else {
                                // 阶段内还有未完成任务 → 自动激活下一个 pending 任务
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
                        for i in 0..tasks.len() {
                            if tasks[i]["status"] == "in_progress" {
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

    // 持久化更新后的 plan — 只写状态（task_status + completed_concepts）
    let now = chrono::Utc::now().to_rfc3339();
    let task_status = extract_task_status(&plan);
    let mut status_update = serde_json::json!({"task_status": task_status});
    if let Some(concepts) = plan.get("completed_concepts") {
        status_update["completed_concepts"] = concepts.clone();
    }

    // 检测是否有 sub_steps 变更（需要同时更新 plan_content）
    let has_sub_steps = plan.get("stages").and_then(|s| s.as_array())
        .map(|stages| stages.iter().any(|s| s["tasks"].as_array()
            .map(|t| t.iter().any(|x| x.get("sub_steps").is_some())).unwrap_or(false)))
        .unwrap_or(false);

    if has_sub_steps {
        if let Err(e) = conn.execute(
            "UPDATE learning_plans SET plan_content = ?1, plan_json = ?2, updated_at = ?3 WHERE id = ?4",
            rusqlite::params![plan.to_string(), status_update.to_string(), now, plan_id],
        ) {
            tracing::error!("Plan mutation DB+content write failed: {} (plan_id={})", e, plan_id);
            return None;
        }
    } else {
        let _ = conn.execute(
            "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE id = ?3",
            rusqlite::params![status_update.to_string(), now, plan_id],
        );
    }

    Some(plan)
}

/// 从完整 plan 中提取 task → status 映射（用于 plan_json 状态存储）
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
        "SELECT id, plan_json, plan_content FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        )),
    ).ok();

    let (plan_id, plan_json_str, plan_content_raw) = plan_row?;
    let status_val: serde_json::Value = serde_json::from_str(&plan_json_str).ok()?;
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

    let now = chrono::Utc::now().to_rfc3339();
    let task_status = extract_task_status(&plan);
    let status_update = serde_json::json!({"task_status": task_status});
    if let Err(e) = conn.execute(
        "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE id = ?3",
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
        "你是一位教学评估专家。你的任务是判断学生是否已掌握当前课文的核心教学点。\n\
         \n\
         评估标准：\n\
         - 学生能用具体语言内容展示理解（不只是说“我懂了”）\n\
         - 学生能分析手法、意象、语言特色等教学点\n\
         - 学生能概括主旨思想\n\
         - 学生能回答教师的考核问题\n\
         \n\
         如果学生展示的深度足够推进到下一课，回复 JSON：{\"should_advance\": true, \"reason\": \"理由\"}\n\
         如果学生还未能掌握，回复 JSON：{\"should_advance\": false, \"reason\": \"理由\"}\n\
         只输出 JSON，不要其他内容。"
    } else {
        "你是一位教学评估专家。你的任务是判断学生是否已掌握当前任务的知识点。\n\
         \n\
         评估标准：\n\
         - 学生能用具体知识内容展示理解\n\
         - 学生能正确回答教师的问题\n\
         - 多轮对话中学生表现出了实质进步\n\
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
fn get_current_reading_task(plan_json: &serde_json::Value, plan_content_raw: &Option<String>) -> Option<(String, String)> {
    // 从 plan_content 取任务顺序
    let content_str = plan_content_raw.as_ref()?;
    let content: serde_json::Value = serde_json::from_str(content_str).ok()?;
    let stages = content.get("stages")?.as_array()?;

    // 从 plan_json 取 task_status
    let task_status = plan_json.get("task_status")
        .and_then(|s| s.as_object())
        .or_else(|| plan_json.as_object())?;

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
    let plan_row = conn.query_row(
        "SELECT mode, goal, plan_json, plan_content, domain FROM learning_plans WHERE conversation_id = ?1 AND (mode = 'structured' OR mode = 'reading') ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, String>(4)?,
        )),
    ).ok().and_then(|(mode, goal, plan_json, plan_content, domain)| {
        mode.map(|m| (m, goal, plan_json, plan_content, domain))
    });

    match plan_row {
        Some((mode, goal, plan_json, plan_content_raw, _domain)) if mode == "structured" || mode == "reading" => {
            // 合并 content（plan_content / loader）与 status（plan_json）
            let status_val: serde_json::Value = serde_json::from_str(&plan_json).unwrap_or_default();
            let task_status = status_val.as_object()
                .and_then(|o| o.get("task_status"))
                .or_else(|| Some(&status_val)); // 兼容直接存 map 的格式

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
                if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
                    'outer: for stage in stages {
                        if let Some(tasks) = stage["tasks"].as_array() {
                            for task in tasks {
                                let tstatus = task["status"].as_str().unwrap_or("pending");
                                if tstatus != "done" {
                                    let tname = task["name"].as_str().unwrap_or("");
                                    let reading_ctx = crate::reading_loader::build_reading_context(&merged, tname);
                                    ctx.push_str(&reading_ctx);
                                    break 'outer;
                                }
                            }
                        }
                    }
                }
                (pipeline_domain, "reading".to_string(), ctx)
            } else {
                // Structured 模式：仅列出 task 名称
                if let Some(stages) = merged.get("stages").and_then(|v| v.as_array()) {
                    for stage in stages {
                        let name = stage["name"].as_str().unwrap_or("");
                        let status = stage["status"].as_str().unwrap_or("pending");
                        if status == "in_progress" || status == "pending" {
                            ctx.push_str(&format!("\n当前阶段: {} ({})", name, status));
                            if let Some(tasks) = stage["tasks"].as_array() {
                                for task in tasks {
                                    let tname = task["name"].as_str().unwrap_or("");
                                    let tstatus = task["status"].as_str().unwrap_or("pending");
                                    ctx.push_str(&format!("\n  - {}: {}", tname, tstatus));
                                }
                            }
                            break;
                        }
                    }
                }
                (pipeline_domain, "structured".to_string(), ctx)
            }
        }
        _ => ("".to_string(), "free".to_string(), String::new()),
    }
}

/// 构建计划分析 prompt（用于 ColdPath 2）
/// pass_rate_info: 可选的客观通过率描述文本（如 "客观完成率：当前任务通过率 75%（需 ≥ 80%）"）
pub fn build_plan_analysis_prompt(
    conversation_history: &[(String, String)],
    plan_json: &serde_json::Value,
    pass_rate_info: Option<&str>,
) -> String {
    let dialogue: Vec<String> = conversation_history.iter()
        .map(|(role, content)| {
            let label = if role == "user" { "学生" } else { "教师" };
            format!("{}: {}", label, content)
        })
        .collect();
    let dialogue_text = dialogue.join("\n");

    let stages_text: String = if let Some(stages) = plan_json.get("stages").and_then(|v| v.as_array()) {
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

    format!(
        r#"你是一位学习计划分析器。你的任务是根据师生对话内容，分析学习进度并输出计划更新。

【当前计划】
目标: {}
{stages_text}
{pass_rate_line}
【最近对话】
{dialogue_text}（注意只分析教学相关的部分，忽略寒暄）

请分析：
1. 学生当前是否完成了某个概念或任务？(completed_concepts)
2. 当前任务(Task)是否应该标记为完成？(current_task_complete: true/false)
3. 如果当前阶段(stage)所有任务都完成了，是否应该推进到下一阶段？

只返回 JSON 格式（不要加任何其他文字）：
{{"completed_concepts": ["概念1", "概念2"], "current_task_complete": true/false, "next_stage_suggestion": null或"阶段名称"}}
"#,
        plan_json.get("goal").and_then(|v| v.as_str()).unwrap_or(""),
        stages_text = stages_text,
        dialogue_text = dialogue_text,
        pass_rate_line = pass_rate_info.map(|p| format!("\n{}\n", p)).unwrap_or_default(),
    )
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
            "SELECT plan_json, plan_content, mode FROM learning_plans WHERE conversation_id = ?1 ORDER BY updated_at DESC LIMIT 1",
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
        Some((plan_json_str, plan_content_raw, mode)) => {
            let plan_json: serde_json::Value = match serde_json::from_str(&plan_json_str) {
                Ok(v) => v,
                Err(_) => return false,
            };

            // 根据 mode 选择评估方式
            let is_reading = mode.as_deref() == Some("reading");

            if is_reading {
                // 课文阅读模式：使用 auto_advance_check
                let recent: Vec<(String, String)> = relevant.into_iter().rev().take(6).collect();
                let current_task = get_current_reading_task(&plan_json, &plan_content_raw);
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
                    let tag = format!("<reading_update>{{\"complete_current_task\": true}}</reading_update>");
                    let result = handle_plan_update(&conn, &tag, &conv_id, &uid);
                    tracing::info!("Reading auto-advance: task={}, reason={}, updated={}",
                        task_name, reason, result.plan_updated);
                    result.plan_updated
                } else {
                    false
                }
            } else {
            // 合并 plan_content + plan_json(task_status) → 全量 plan（供分析使用）
            let merged_plan: serde_json::Value = if let Some(ref content_str) = plan_content_raw {
                if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                    let smap = plan_json.get("task_status")
                        .and_then(|s| s.as_object())
                        .or_else(|| plan_json.as_object());
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
                } else { plan_json.clone() }
            } else { plan_json.clone() };

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
            // 合并 plan_content + plan_json(task_status) → 全量 plan（供分析使用）
            let merged_plan: serde_json::Value = if let Some(ref content_str) = plan_content_raw {
                if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                    let smap = plan_json.get("task_status")
                        .and_then(|s| s.as_object())
                        .or_else(|| plan_json.as_object());
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
                } else { plan_json.clone() }
            } else { plan_json.clone() };
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
                    if result.plan_updated {
                        unlock_next_cards(&conn, &conv_id, &uid, &plan_json);
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

            let prompt = format!(
                r#"根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{}

请输出 JSON 格式的学习计划，包含：
- goal: 学习目标（根据对话推断）
- domain: 领域（math/language/chemistry/biology 之一）
- stages: 阶段数组，每个阶段包含 name、status（in_progress/pending/completed）、tasks 数组
- 每项 task 包含 name、status、description
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

确保计划包含 3-5 个阶段，每个阶段 2-3 个任务，覆盖完整的学习路径。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}
"#,
                dialogue_text
            );

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

/// 卡片渐进解锁：当任务完成后，解锁下一批预置卡片
fn unlock_next_cards(
    conn: &rusqlite::Connection,
    conversation_id: &str,
    user_id: &str,
    plan_json: &serde_json::Value,
) {
    // 从计划中找第一个 status != "done" 且 != "completed" 的 task
    let next_ids: Option<Vec<String>> = (|| {
        let stages = plan_json.get("stages").and_then(|v| v.as_array())?;
        let mut found_complete = false;
        for stage in stages {
            let tasks = stage.get("tasks").and_then(|v| v.as_array())?;
            for task in tasks {
                let status = task.get("status").and_then(|v| v.as_str()).unwrap_or("pending");
                if status == "in_progress" || status == "pending" {
                    // 如果是第一个 in_progress/pending 且 found_complete=false → 跳过（当前任务）
                    if !found_complete {
                        // 检查这个 task 是否已完成
                        let task_name = task.get("name").and_then(|v| v.as_str()).unwrap_or("");
                        if crate::k12_quiz::should_mark_task_complete(conn, user_id, task_name) {
                            found_complete = true;
                            continue;
                        }
                        // 未完成 → 当前任务还在进行，不需解锁
                        return None;
                    }
                    // 找到了下一个任务，返回它的 gold_cr_ids
                    return task.get("gold_cr_ids")
                        .and_then(|v| v.as_array())
                        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect());
                }
            }
        }
        None
    })();

    if let Some(next_ids) = next_ids {
        if next_ids.is_empty() { return; }

        let now_ts = chrono::Utc::now().timestamp();
        // 从 curriculum_loader 获取预置卡片模板，匹配 gold_cr_id 导入
        // 先查 conversation 的 subject/grade_band
        let (subject, grade_band): (Option<String>, Option<String>) = conn.query_row(
            "SELECT subject, grade_band FROM conversations WHERE id = ?1",
            rusqlite::params![conversation_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).unwrap_or((None, None));

        let (subj, grade) = match (subject, grade_band) {
            (Some(s), Some(g)) => (s, g),
            _ => return,
        };

        let cards = crate::curriculum_loader::get_cards(&subj, &grade);
        if let Some(card_list) = cards {
            for card_tmpl in card_list {
                // 概念卡：gold_cr_ids 与下一任务的 gold_cr_ids 有交集
                // 词卡：plan_task_id 等于下一任务 name
                if !next_ids.is_empty() && !card_tmpl.gold_cr_ids.iter().any(|g| next_ids.contains(g)) {
                    continue;
                }
                let card_id = format!("k12_{}", &card_tmpl.id);
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, k12_card_id)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    rusqlite::params![card_id, user_id, card_tmpl.domain, card_tmpl.card_type,
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
    let now = chrono::Utc::now().to_rfc3339();
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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, plan_json TEXT, created_at TEXT, updated_at TEXT);
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
        let plan_json_status = json!({"task_status": {"Task1": "in_progress", "Task2": "pending"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, plan_json=?2 WHERE id='p1'",
            rusqlite::params![plan_content.to_string(), plan_json_status.to_string()]).unwrap();

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

        let plan = result.plan_json.unwrap();
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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, plan_json TEXT, created_at TEXT, updated_at TEXT);
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
        let plan_json_status = json!({"task_status": {"Task1": "done", "Task2": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, plan_json=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), plan_json_status.to_string()]).unwrap();

        // LLM 意识到超前，发送回退
        let reply = format!("抱歉我跳得太快了\n\n<plan_update>\n{}\n</plan_update>", json!({
            "reset_current_task": true
        }));

        let result = handle_plan_update(&conn, &reply, "c1", "u1");
        assert!(result.plan_updated, "plan should be updated");

        let plan = result.plan_json.unwrap();
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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, plan_json TEXT, created_at TEXT, updated_at TEXT);
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
        let plan_json_status = json!({"task_status": {"Task1": "done", "Task2": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, plan_json=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), plan_json_status.to_string()]).unwrap();

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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_content TEXT DEFAULT NULL, plan_json TEXT, created_at TEXT, updated_at TEXT);
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
        let plan_json_status = json!({"task_status": {"Task1": "in_progress"}});
        conn.execute("UPDATE learning_plans SET plan_content=?1, plan_json=?2 WHERE id='p1'",
            rusqlite::params![plan.to_string(), plan_json_status.to_string()]).unwrap();

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
        let quiz_status = result2.plan_json.as_ref().unwrap()["stages"][0]["tasks"][0]["sub_steps"]["quiz"].as_str().unwrap();
        assert_eq!(quiz_status, "done");

        // 现在推进 — 应成功
        let reply3 = format!("<plan_update>\n{}\n</plan_update>", json!({
            "current_task_complete": true
        }));
        let result3 = handle_plan_update(&conn, &reply3, "c1", "u1");
        assert!(result3.plan_updated, "sub_steps all done → should complete");
        assert_eq!(result3.plan_json.unwrap()["stages"][0]["tasks"][0]["status"], "done");
    }
}
