//! L2 评估 prompt 构建 + 响应解析
//! 维度：teacher（教师质量）、card（卡片质量）

use k12_tests::LifecycleLog;
use crate::{TeacherScore, CardScore, QualityIssue};

/// 构建教师评估 prompt
pub fn build_teacher_prompt(log: &LifecycleLog) -> String {
    let teacher_turns: Vec<String> = log.llm_calls.iter()
        .filter(|c| c.step.contains("_teacher") || c.step.starts_with("progression_turn"))
        .map(|c| {
            let chars: Vec<char> = c.response.chars().collect();
            let response = if chars.len() > 800 {
                let truncated: String = chars[..800].iter().collect();
                format!("{}...", truncated)
            } else { c.response.clone() };
            format!("[{}]\n{}", c.step, response)
        })
        .collect();

    format!(
        r#"你是一位教育评估专家。以下是 AI 教师在 {subject}（{grade_band} 水平）教学中的对话。

请从以下 3 个维度评分（每项 0-100）：
1. 内容正确性（correctness）：讲解内容有没有知识性错误？
2. 年级适配度（grade_fit）：难度和语言是否符合 {grade_band} 学生？
3. 结构清晰度（structure）：是否按'讲解→举例→练习→考核'推进？

教学对话：
{dialogue}

只返回 JSON，格式：
{{"correctness": 分数, "grade_fit": 分数, "structure": 分数, "issues": ["问题1", "问题2"]}}
"#,
        subject = log.subject,
        grade_band = log.grade_band,
        dialogue = teacher_turns.join("\n---\n"),
    )
}

/// 构建卡片评估 prompt
pub fn build_card_prompt(log: &LifecycleLog, last_ai_reply: &str) -> String {
    let cards: Vec<String> = log.card_events.iter()
        .filter(|e| e.event == "extracted")
        .map(|e| format!("- front=\"{}\" domain=\"{}\"", e.card_front, e.card_domain))
        .collect();
    let cards_str = if cards.is_empty() { "（无候选概念）".to_string() } else { cards.join("\n") };
    let reply = if last_ai_reply.chars().count() > 2000 {
        let chars: Vec<char> = last_ai_reply.chars().collect();
        let truncated: String = chars[..2000].iter().collect();
        format!("{}...", truncated)
    } else { last_ai_reply.to_string() };

    format!(
        r#"以下是从 AI 教学对话中提取的复习卡片。请评估每张卡片的质量。

教学语境（最后 1 轮 AI 回答，前 2000 字）：
{reply}

提取的卡片：
{cards_str}

评分：
1. front_quality：概念名称是否恰当（0-100）
2. back_quality：是否值得作为复习对象（0-100）
3. useful_rate：多少比例有复习价值（0-1）
4. missing_concepts：对话中出现了但未被提取的重要概念列表

只返回 JSON：{{"front_quality": 80, "back_quality": 75, "useful_rate": 0.85, "missing_concepts": [], "comment": "..."}}
"#,
        reply = reply,
        cards_str = cards_str,
    )
}

/// 解析教师评估 LLM 响应
pub fn parse_teacher_response(
    response: &str, log: &LifecycleLog,
) -> (TeacherScore, Vec<QualityIssue>) {
    let mut issues = Vec::new();
    let (correctness, grade_fit, structure) = match serde_json::from_str::<serde_json::Value>(response) {
        Ok(json) => {
            if let Some(arr) = json.get("issues").and_then(|v| v.as_array()) {
                for v in arr {
                    if let Some(msg) = v.as_str() {
                        issues.push(QualityIssue {
                            severity: "info".into(), category: "teacher".into(), message: msg.into(),
                        });
                    }
                }
            }
            (
                json.get("correctness").and_then(|v| v.as_f64()).unwrap_or(50.0),
                json.get("grade_fit").and_then(|v| v.as_f64()).unwrap_or(50.0),
                json.get("structure").and_then(|v| v.as_f64()).unwrap_or(50.0),
            )
        }
        Err(_) => {
            issues.push(QualityIssue {
                severity: "warning".into(), category: "teacher".into(),
                message: "LLM 评估返回非 JSON，使用 L1 降级".into(),
            });
            (0.0, 0.0, 0.0)
        }
    };

    let overall = if correctness > 0.0 {
        correctness * 0.30 + grade_fit * 0.20 + structure * 0.20
            + (log.candidates_extracted.min(10) as f64 / 10.0 * 100.0) * 0.15
            + (log.plan_updates as f64 / log.progression_turns.max(1) as f64 * 100.0) * 0.15
    } else {
        // L1 降级
        (log.candidates_extracted.min(10) as f64 / 10.0 * 100.0) * 0.50
            + (log.plan_updates as f64 / log.progression_turns.max(1) as f64 * 100.0) * 0.50
    };

    (TeacherScore {
        correctness, grade_fit, structure,
        coverage: log.candidates_extracted as f64,
        plan_update_rate: log.plan_updates as f64 / log.progression_turns.max(1) as f64,
        overall,
    }, issues)
}

/// 解析卡片评估 LLM 响应
pub fn parse_card_response(
    response: &str, log: &LifecycleLog,
) -> (CardScore, Vec<QualityIssue>) {
    let mut issues = Vec::new();
    let total_candidates = log.candidates_extracted as f64;
    let domain_accuracy = if total_candidates > 0.0 {
        let ok = log.card_events.iter().filter(|e| e.event == "extracted" && e.card_domain == log.domain).count() as f64;
        ok / total_candidates
    } else { 0.0 };
    let dedup_rate = if total_candidates > 0.0 {
        let dup = log.errors.iter().filter(|e| e.starts_with("card_dup")).count() as f64;
        (total_candidates - dup) / total_candidates
    } else { 1.0 };

    let (front_quality, back_quality, useful_rate) = match serde_json::from_str::<serde_json::Value>(response) {
        Ok(json) => {
            if let Some(missing) = json.get("missing_concepts").and_then(|v| v.as_array()) {
                for v in missing {
                    if let Some(name) = v.as_str() {
                        issues.push(QualityIssue {
                            severity: "info".into(), category: "card".into(),
                            message: format!("缺失概念: {}", name),
                        });
                    }
                }
            }
            (
                json.get("front_quality").and_then(|v| v.as_f64()).unwrap_or(50.0),
                json.get("back_quality").and_then(|v| v.as_f64()).unwrap_or(50.0),
                json.get("useful_rate").and_then(|v| v.as_f64()).unwrap_or(0.5),
            )
        }
        Err(_) => {
            issues.push(QualityIssue {
                severity: "warning".into(), category: "card".into(),
                message: "LLM 评估返回非 JSON，使用 L1 降级".into(),
            });
            (0.0, 0.0, 0.0)
        }
    };

    let overall = if front_quality > 0.0 {
        (total_candidates.min(10.0) / 10.0 * 100.0) * 0.15
            + domain_accuracy * 100.0 * 0.15
            + front_quality * 0.25
            + back_quality * 0.25
            + dedup_rate * 100.0 * 0.10
            + useful_rate * 100.0 * 0.10
    } else {
        (total_candidates.min(10.0) / 10.0 * 100.0) * 0.50
    };

    (CardScore {
        candidate_count: total_candidates, domain_accuracy,
        front_quality, back_quality, dedup_rate, useful_rate,
        overall,
    }, issues)
}

/// 构建学生模拟评估 prompt
pub fn build_student_prompt(log: &LifecycleLog) -> String {
    let student_turns: Vec<String> = log.llm_calls.iter()
        .filter(|c| c.step.contains("_student"))
        .map(|c| format!("[{}]\n{}", c.step, c.response))
        .collect();
    if student_turns.is_empty() {
        return String::new();
    }

    format!(
        r#"你是一位教育评估专家。以下是 AI 模拟学生在 {subject} 课堂上的回答。

请从以下 5 个维度评分（每项 0-100）：
1. 错误率（error_rate）：学生是否偶尔犯错？真实学生会答错、记混。
2. 语域自然度（naturalness）：是否用口语化表达？短句、填充词、语气词？
3. 追问率（questioning_rate）：是否主动问"为什么""能再举个例子"？
4. 多样性（diversity）：每次回答的句式和长度是否有变化？
5. 理解深度（understanding_depth）：是机械复述还是体现了真实思考？

学生对话：
{dialogue}

只返回 JSON，格式：
{{"error_rate": 分数, "naturalness": 分数, "questioning_rate": 分数, "diversity": 分数, "understanding_depth": 分数, "issues": ["问题"]}}
"#,
        subject = log.subject,
        dialogue = student_turns.join("\n---\n"),
    )
}

/// 解析学生评估 LLM 响应
pub fn parse_student_response(response: &str) -> (crate::StudentScore, Vec<QualityIssue>) {
    let mut issues = Vec::new();
    match serde_json::from_str::<serde_json::Value>(response) {
        Ok(json) => {
            if let Some(arr) = json.get("issues").and_then(|v| v.as_array()) {
                for v in arr {
                    if let Some(msg) = v.as_str() {
                        issues.push(QualityIssue { severity: "info".into(), category: "student".into(), message: msg.into() });
                    }
                }
            }
            let error_rate = json.get("error_rate").and_then(|v| v.as_f64()).unwrap_or(50.0);
            let naturalness = json.get("naturalness").and_then(|v| v.as_f64()).unwrap_or(50.0);
            let questioning_rate = json.get("questioning_rate").and_then(|v| v.as_f64()).unwrap_or(50.0);
            let diversity = json.get("diversity").and_then(|v| v.as_f64()).unwrap_or(50.0);
            let understanding_depth = json.get("understanding_depth").and_then(|v| v.as_f64()).unwrap_or(50.0);
            let overall = error_rate * 0.25 + naturalness * 0.25 + questioning_rate * 0.20 + diversity * 0.15 + understanding_depth * 0.15;
            (crate::StudentScore { error_rate, naturalness, questioning_rate, diversity, understanding_depth, overall }, issues)
        }
        Err(_) => {
            issues.push(QualityIssue { severity: "warning".into(), category: "student".into(), message: "LLM 评估返回非 JSON".into() });
            (crate::StudentScore { error_rate: 0.0, naturalness: 0.0, questioning_rate: 0.0, diversity: 0.0, understanding_depth: 0.0, overall: 0.0 }, issues)
        }
    }
}

/// 加载课标摘要
pub fn load_curriculum_guide() -> Option<serde_json::Value> {
    for path in &[
        "docs/curriculum/curriculum_guide.json",
        "../docs/curriculum/curriculum_guide.json",
    ] {
        if let Ok(content) = std::fs::read_to_string(path) {
            if let Ok(v) = serde_json::from_str(&content) {
                return Some(v);
            }
        }
    }
    // 也尝试绝对路径
    let hardcoded = r#"E:\CoEvo\docs\curriculum\curriculum_guide.json"#;
    if let Ok(content) = std::fs::read_to_string(hardcoded) {
        if let Ok(v) = serde_json::from_str(&content) {
            return Some(v);
        }
    }
    None
}

/// 计算课标覆盖度
/// 返回: (已覆盖条目数, 总条目数, 覆盖率0-1, 缺失条目列表)
pub fn compute_curriculum_coverage(
    log: &LifecycleLog,
    guide: &serde_json::Value,
) -> (u32, u32, f64, Vec<String>) {
    let subject = &log.subject;
    let band = &log.grade_band;

    // 获取课标条目
    let category = if band.starts_with("g10") { "高中" } else { "义务教育" };
    let items: Vec<String> = guide["subjects"][subject][category][band]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();

    if items.is_empty() {
        return (0, 0, 0.0, vec!["无课标数据".to_string()]);
    }

    // 提取教师所有回复文本
    let all_text: String = log.llm_calls.iter()
        .filter(|c| c.step.contains("_teacher") || c.step.starts_with("progression_turn"))
        .map(|c| c.response.as_str())
        .collect::<Vec<_>>()
        .join(" ");

    let total = items.len() as u32;
    let mut covered = 0u32;
    let mut missing = Vec::new();

    for item in &items {
        // 拆成关键词，支持多种分隔符
        // "万以内数的认识与四则运算" → ["万以内数", "四则运算"]
        // "小数与分数的初步认识" → ["小数", "分数"]
        // "长方形/正方形的周长与面积" → ["长方形", "正方形", "周长", "面积"]
        // "代数式、方程与不等式(一元一次/二元一次/一元二次)" → ["代数式", "方程", "不等式"]
        let mut keywords: Vec<String> = item
            .split(&['/', '与', '、', '，', ',', '（', '('][..])
            .flat_map(|s| s.split('）'))
            .flat_map(|s| s.split(')'))
            .map(|s| s.trim().to_string())
            .filter(|s| s.len() >= 2 && s.len() <= 12) // 太长的词继续拆分
            .collect();

        // 对仍然太长的词（如"代数式、方程与不等式"）进一步按停用词拆
        let mut finer: Vec<String> = Vec::new();
        for kw in &keywords {
            for sep in &["的", "与", "及", "、"] {
                if kw.contains(sep) && kw.len() > 8 {
                    for part in kw.split(sep) {
                        let part = part.trim();
                        if part.len() >= 2 {
                            finer.push(part.to_string());
                        }
                    }
                    finer.push(kw.clone()); // 保留原词
                    break;
                }
            }
        }
        if !finer.is_empty() {
            keywords.extend(finer);
        }

        // 去重
        keywords.sort();
        keywords.dedup();

        // 检查教师回复是否包含这些关键词之一
        let matched = keywords.iter().any(|kw| all_text.contains(kw.as_str()));
        if matched {
            covered += 1;
        } else {
            missing.push(item.clone());
        }
    }

    let rate = if total > 0 { covered as f64 / total as f64 } else { 0.0 };
    (covered, total, rate, missing)
}