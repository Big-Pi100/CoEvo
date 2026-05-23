//! 聚合报告生成

use std::collections::HashMap;
use crate::{QualityEval, CompositeScore};

/// 聚合报告
#[derive(Debug, Clone)]
pub struct AggregatedReport {
    pub total: usize,
    pub grade_counts: HashMap<String, usize>,
    pub avg_scores: HashMap<String, f64>,
    pub issues: Vec<String>,
    pub per_subject: Vec<SubjectSummary>,
}

#[derive(Debug, Clone)]
pub struct SubjectSummary {
    pub subject: String,
    pub grade_band: String,
    pub teacher: f64,
    pub card: f64,
    pub plan: f64,
    pub composite: f64,
    pub grade: String,
}

/// 生成聚合报告
pub fn aggregate(results: &[QualityEval]) -> AggregatedReport {
    let total = results.len();
    let mut grade_counts: HashMap<String, usize> = HashMap::new();
    let mut score_sums: HashMap<String, f64> = HashMap::new();
    let mut score_counts: HashMap<String, usize> = HashMap::new();
    let mut per_subject = Vec::new();

    for r in results {
        *grade_counts.entry(r.scores.composite.grade.clone()).or_insert(0) += 1;

        let dims = [
            ("teacher", r.scores.teacher.as_ref().map(|s| s.overall)),
            ("card", r.scores.card.as_ref().map(|s| s.overall)),
            ("plan", r.scores.plan.as_ref().map(|s| s.overall)),
            ("composite", Some(r.scores.composite.total)),
        ];
        for (name, score) in &dims {
            if let Some(s) = score {
                *score_sums.entry(name.to_string()).or_insert(0.0) += s;
                *score_counts.entry(name.to_string()).or_insert(0) += 1;
            }
        }

        per_subject.push(SubjectSummary {
            subject: r.subject.clone(),
            grade_band: r.grade_band.clone(),
            teacher: r.scores.teacher.as_ref().map(|s| s.overall).unwrap_or(0.0),
            card: r.scores.card.as_ref().map(|s| s.overall).unwrap_or(0.0),
            plan: r.scores.plan.as_ref().map(|s| s.overall).unwrap_or(0.0),
            composite: r.scores.composite.total,
            grade: r.scores.composite.grade.clone(),
        });
    }

    let mut avg_scores = HashMap::new();
    for (name, sum) in &score_sums {
        let count = score_counts.get(name).copied().unwrap_or(1);
        avg_scores.insert(name.clone(), (sum / count as f64 * 100.0).round() / 100.0);
    }

    let issues: Vec<String> = results.iter()
        .flat_map(|r| r.issues.iter().map(|i| format!("[{}] {}: {}", r.subject, i.category, i.message)))
        .collect();

    AggregatedReport { total, grade_counts, avg_scores, issues, per_subject }
}

pub fn render_report_text(report: &AggregatedReport) -> String {
    let mut out = String::new();
    out.push_str(&format!("# 质量评估报告\n\n"));
    out.push_str(&format!("> 总测试数: {}\n\n", report.total));

    out.push_str("## 等级分布\n\n");
    out.push_str("| 等级 | 数量 |\n|------|:----:|\n");
    let mut grades: Vec<_> = report.grade_counts.iter().collect();
    grades.sort_by_key(|(g, _)| match g.as_str() { "A" => 0, "B" => 1, "C" => 2, "D" => 3, "F" => 4, _ => 5 });
    for (g, c) in &grades {
        out.push_str(&format!("| {} | {} |\n", g, c));
    }

    out.push_str("\n## 各维度平均分\n\n");
    out.push_str("| 维度 | 平均分 |\n|------|:----:|\n");
    for name in &["teacher", "student", "card", "plan", "review", "composite"] {
        if let Some(avg) = report.avg_scores.get(*name) {
            let label = match *name {
                "teacher" => "教师质量",
                "card" => "卡片质量",
                "plan" => "计划执行",
                "composite" => "综合评分",
                _ => name,
            };
            out.push_str(&format!("| {} | {:.1} |\n", label, avg));
        }
    }

    out.push_str("\n## 各用例评分\n\n");
    out.push_str("| 学段 | 科目 | 教师 | 学生 | 卡片 | 计划 | 复习 | 综合 | 等级 |\n");
    out.push_str("|------|------|:----:|:----:|:----:|:----:|:----:|:----:|:----:|\n");
    for s in &report.per_subject {
        out.push_str(&format!("| {} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {} |\n",
            s.grade_band, s.subject, s.teacher, 0.0, s.card, s.plan, 0.0, s.composite, s.grade));
    }

    if !report.issues.is_empty() {
        out.push_str("\n## 问题汇总\n\n");
        for iss in &report.issues {
            out.push_str(&format!("- {}\n", iss));
        }
    }

    out
}
