//! 学习计划处理 — WebSocket 和 REST 共用模块
//!
//! 负责:
//!   1. 解析 LLM 回复中的 <plan_update>...</plan_update> XML 标签
//!   2. 创建/更新 learning_plans 表
//!   3. 返回清理后的回复文本

use serde_json::json;

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

    // 用 <plan_update 匹配（可能被截断）
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

    if let Some(existing_id) = existing_plan {
        if let Err(e) = conn.execute(
            "UPDATE learning_plans SET goal=?1, plan_json=?2, domain=?3, updated_at=?4 WHERE id=?5",
            rusqlite::params![goal, plan.to_string(), domain, now, existing_id],
        ) {
            tracing::error!("Learning plan update failed: {} (plan_id={})", e, existing_id);
        } else {
            tracing::debug!("Learning plan updated: {}", existing_id);
        }
    } else {
        let id = uuid::Uuid::new_v4().to_string();
        if let Err(e) = conn.execute(
            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?7)",
            rusqlite::params![id, user_id, conversation_id, goal, domain, plan.to_string(), now],
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
    let plan_row: Option<(String, String)> = conn.query_row(
        "SELECT id, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
    ).ok();

    let (plan_id, plan_str) = plan_row?;
    let mut plan = serde_json::from_str::<serde_json::Value>(&plan_str).ok()?;

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

    // 持久化更新后的 plan
    let now = chrono::Utc::now().to_rfc3339();
    if let Err(e) = conn.execute(
        "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![plan.to_string(), now, plan_id],
    ) {
        tracing::error!("Plan mutation DB write failed: {} (plan_id={})", e, plan_id);
        return None;  // 写入失败则不返回 plan，避免前端加载到旧数据
    }

    Some(plan)
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
    let plan_row: Option<(String, String)> = conn.query_row(
        "SELECT id, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
    ).ok();

    let (plan_id, plan_str) = plan_row?;
    let mut plan = serde_json::from_str::<serde_json::Value>(&plan_str).ok()?;

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
    if let Err(e) = conn.execute(
        "UPDATE learning_plans SET plan_json = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![plan.to_string(), now, plan_id],
    ) {
        tracing::error!("Auto-revert DB write failed: {} (plan_id={})", e, plan_id);
        return None;
    }

    tracing::info!("Auto-revert applied for conversation {}", conversation_id);
    Some(plan)
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
        "SELECT mode, goal, plan_json, domain FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![conversation_id],
        |row| Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        )),
    ).ok().and_then(|(mode, goal, plan_json, domain)| {
        mode.map(|m| (m, goal, plan_json, domain))
    });

    match plan_row {
        Some((mode, goal, plan_json, _domain)) if mode == "structured" => {
            // 从 plan_json 中读取 pipeline_domain
            let pipeline_domain: String = serde_json::from_str::<serde_json::Value>(&plan_json).ok()
                .and_then(|plan| {
                    // 先尝试 pipeline_domain，再尝试 domain
                    if let Some(d) = plan.get("pipeline_domain").and_then(|d| d.as_str()) {
                        return Some(d.to_string());
                    }
                    plan.get("domain").and_then(|d| d.as_str()).map(|s| s.to_string())
                })
                .unwrap_or_default();

            let mut ctx = format!("\n\n### 学习计划\n长期目标: {}", goal);
            if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&plan_json) {
                if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
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
            }
            (pipeline_domain, "structured".to_string(), ctx)
        }
        _ => ("".to_string(), "free".to_string(), String::new()),
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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_json TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', ?, '2024-01-01', '2024-01-01');
        ").unwrap();

        // 初始计划：Task1 in_progress, Task2 pending
        let plan = json!({
            "stages": [{
                "name": "基础", "status": "in_progress",
                "tasks": [
                    {"name": "Task1", "status": "in_progress"},
                    {"name": "Task2", "status": "pending"}
                ]
            }],
            "completed_concepts": []
        });
        conn.execute("UPDATE learning_plans SET plan_json=?1 WHERE id='p1'",
            rusqlite::params![plan.to_string()]).unwrap();

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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_json TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', ?, '2024-01-01', '2024-01-01');
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
        conn.execute("UPDATE learning_plans SET plan_json=?1 WHERE id='p1'",
            rusqlite::params![plan.to_string()]).unwrap();

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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_json TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', ?, '2024-01-01', '2024-01-01');
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
        conn.execute("UPDATE learning_plans SET plan_json=?1 WHERE id='p1'",
            rusqlite::params![plan.to_string()]).unwrap();

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
            CREATE TABLE learning_plans (id TEXT, user_id TEXT, conversation_id TEXT, goal TEXT, domain TEXT, mode TEXT, plan_json TEXT, created_at TEXT, updated_at TEXT);
            INSERT INTO learning_plans VALUES ('p1', 'u1', 'c1', 'test', '', 'structured', ?, '2024-01-01', '2024-01-01');
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
        conn.execute("UPDATE learning_plans SET plan_json=?1 WHERE id='p1'",
            rusqlite::params![plan.to_string()]).unwrap();

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
