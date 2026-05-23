//! Pipeline 2：质量评估管线
//!
//! 读取 Pipeline 1 产出的 LifecycleLog JSON，逐用例评估：
//! - teacher（L2）：第二条 LLM 审查教师回答质量
//! - card（L2）：第二条 LLM 审查卡片提取质量
//! - plan（L1）：自动计算计划执行度
//! - review（L1）：自动计算复习流程分数
//!
//! 用法:
//!   cargo run --bin e2e-quality-eval -- --input docs/k12-results/k12-20260522_091419/
//!   cargo run --bin e2e-quality-eval -- --input <dir> --dimensions teacher,card
//!   cargo run --bin e2e-quality-eval -- --input <dir> --all
//!   cargo run --bin e2e-quality-eval -- --input <dir> --report-only

use std::path::PathBuf;
use std::time::Instant;
use quality_eval::reader;
use quality_eval::evaluator;
use quality_eval::score;
use quality_eval::report::{self, AggregatedReport};
use quality_eval::{QualityEval, QualityScores, CompositeScore, LlmEvalLog, QualityIssue};
use k12_tests::LifecycleLog;

struct CliArgs {
    input: String,
    dimensions: Vec<String>,
    all: bool,
    report_only: bool,
    concurrency: usize,
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut cli = CliArgs {
        input: String::new(),
        dimensions: vec!["teacher".into(), "card".into()],
        all: false, report_only: false, concurrency: 2,
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--input" | "-i" => { i += 1; if let Some(v) = args.get(i) { cli.input = v.clone(); } }
            "--dimensions" | "-d" => { i += 1; if let Some(v) = args.get(i) { cli.dimensions = v.split(',').map(String::from).collect(); } }
            "--all" | "-a" => { cli.all = true; }
            "--report-only" | "-r" => { cli.report_only = true; }
            "--concurrency" | "-c" => { i += 1; if let Some(v) = args.get(i).and_then(|v| v.parse().ok()) { cli.concurrency = v; } }
            _ => {}
        }
        i += 1;
    }
    if cli.all {
        cli.dimensions = vec!["teacher".into(), "card".into(), "plan".into(), "review".into(), "student".into()];
    }
    cli
}

fn find_latest_run() -> Option<String> {
    let base = PathBuf::from("docs/k12-results");
    if !base.is_dir() { return None; }
    let mut dirs: Vec<_> = std::fs::read_dir(&base).ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| e.path())
        .collect();
    dirs.sort();
    dirs.last().map(|p| p.to_string_lossy().to_string())
}

#[tokio::main]
async fn main() {
    let cli = parse_args();
    let _ = dotenvy::dotenv();

    let dir = if cli.input.is_empty() {
        match find_latest_run() {
            Some(d) => d,
            None => { eprintln!("未指定 --input 且未找到 docs/k12-results 中的运行记录"); return; }
        }
    } else {
        cli.input.clone()
    };

    println!("🚀 质量评估管线 run");
    println!("   输入目录: {}", dir);
    println!("   评估维度: {}", cli.dimensions.join(", "));
    if cli.report_only {
        println!("   模式: 仅报告（不调用 LLM）");
    }

    let logs = match reader::read_dir(&dir) {
        Ok(v) => v,
        Err(e) => { eprintln!("读取失败: {}", e); return; }
    };
    println!("   测试用例数: {}\n", logs.len());

    let start = Instant::now();
    let mut results: Vec<QualityEval> = Vec::new();
    let run_id = chrono::Local::now().format("eval-%Y%m%d_%H%M%S").to_string();

    for (_path, log) in &logs {
        let eval = evaluate_single(log, &cli).await;
        // 保存每用例评估结果
        let eval_dir = PathBuf::from("docs/quality-results").join(&run_id);
        let _ = std::fs::create_dir_all(&eval_dir);
        let eval_path = eval_dir.join(format!("{}_{}.json", log.subject, log.grade_band));
        if let Ok(json) = serde_json::to_string_pretty(&eval) {
            std::fs::write(&eval_path, &json).ok();
        }
        results.push(eval);
    }

    // 生成报告
    let report = report::aggregate(&results);
    let report_md = report::render_report_text(&report);
    let report_dir = PathBuf::from("docs/quality-results").join(&run_id);
    let _ = std::fs::create_dir_all(&report_dir);
    let _ = std::fs::write(report_dir.join("quality-report.md"), &report_md);

    println!("{}", report_md);
    println!("\n报告: docs/quality-results/{}/quality-report.md", run_id);
    println!("耗时: {:.0}s", start.elapsed().as_secs_f64());
}

async fn evaluate_single(log: &LifecycleLog, cli: &CliArgs) -> QualityEval {
    let mut all_llm_logs: Vec<LlmEvalLog> = Vec::new();
    let mut all_issues: Vec<QualityIssue> = Vec::new();

    // Teacher eval (L2)
    let teacher = if cli.dimensions.contains(&"teacher".into()) && !cli.report_only {
        let prompt = evaluator::build_teacher_prompt(log);
        // 调用 LLM
        let mut caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");
        let mut eval_log = LlmEvalLog { dimension: "teacher".into(), prompt: prompt.clone(), response: String::new() };
        let result = match caller.generate("", &prompt).await {
            Ok(r) => {
                eval_log.response = r.clone();
                let (score, issues) = evaluator::parse_teacher_response(&r, log);
                all_issues.extend(issues);
                all_llm_logs.push(eval_log);
                score
            }
            Err(e) => {
                eval_log.response = format!("LLM 调用失败: {}", e);
                all_llm_logs.push(eval_log);
                all_issues.push(QualityIssue { severity: "error".into(), category: "teacher".into(), message: format!("LLM 调用失败: {}", e) });
                let (score, _) = evaluator::parse_teacher_response("", log);
                score
            }
        };
        result
    } else {
        let (score, _) = evaluator::parse_teacher_response("", log);
        score
    };
    // Student eval (L2)
    let student = if cli.dimensions.contains(&"student".into()) && !cli.report_only {
        let prompt = evaluator::build_student_prompt(log);
        if prompt.is_empty() {
            None
        } else {
            let mut caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");
            let mut eval_log = LlmEvalLog { dimension: "student".into(), prompt: prompt.clone(), response: String::new() };
            match caller.generate("", &prompt).await {
                Ok(r) => {
                    eval_log.response = r.clone();
                    let (score, issues) = evaluator::parse_student_response(&r);
                    all_issues.extend(issues);
                    all_llm_logs.push(eval_log);
                    Some(score)
                }
                Err(e) => {
                    eval_log.response = format!("LLM 调用失败: {}", e);
                    all_llm_logs.push(eval_log);
                    None
                }
            }
        }
    } else { None };

    // Plan (L1)
    let plan = if cli.dimensions.contains(&"plan".into()) {
        Some(score::compute_plan_score(log))
    } else { None };

    // 课标覆盖度（L1）
    if let Some(guide) = evaluator::load_curriculum_guide() {
        let (covered, total, rate, missing) = evaluator::compute_curriculum_coverage(log, &guide);
        if total > 0 {
            all_issues.push(QualityIssue {
                severity: "info".into(), category: "curriculum".into(),
                message: format!("课标覆盖: {}/{} ({:.0}%)", covered, total, rate * 100.0),
            });
            if !missing.is_empty() && missing.len() <= 5 {
                for m in &missing {
                    all_issues.push(QualityIssue {
                        severity: "info".into(), category: "curriculum".into(),
                        message: format!("未覆盖概念: {}", m),
                    });
                }
            }
        }
    }

    // Card eval (L2)
    let card = if cli.dimensions.contains(&"card".into()) {
        let last_ai_reply = log.llm_calls.iter()
            .filter(|c| c.step.contains("_teacher"))
            .last()
            .map(|c| c.response.as_str())
            .unwrap_or("");
        if !cli.report_only && !last_ai_reply.is_empty() {
            let prompt = evaluator::build_card_prompt(log, last_ai_reply);
            let mut caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");
            let mut eval_log = LlmEvalLog { dimension: "card".into(), prompt: prompt.clone(), response: String::new() };
            let result = match caller.generate("", &prompt).await {
                Ok(r) => {
                    eval_log.response = r.clone();
                    let (score, issues) = evaluator::parse_card_response(&r, log);
                    all_issues.extend(issues);
                    all_llm_logs.push(eval_log);
                    score
                }
                Err(e) => {
                    eval_log.response = format!("LLM 调用失败: {}", e);
                    all_llm_logs.push(eval_log);
                    all_issues.push(QualityIssue { severity: "error".into(), category: "card".into(), message: format!("LLM 调用失败: {}", e) });
                    let (score, _) = evaluator::parse_card_response("", log);
                    score
                }
            };
            result
        } else {
            let (score, _) = evaluator::parse_card_response("", log);
            score
        }
    } else {
        let (score, _) = evaluator::parse_card_response("", log);
        score
    };

    // Review (L1)
    let review = if cli.dimensions.contains(&"review".into()) {
        Some(score::compute_review_score(log))
    } else { None };

    let composite = score::compute_composite(
        teacher.overall.into(),
        None,
        plan.as_ref().map(|s| s.overall),
        card.overall.into(),
        review.as_ref().map(|s| s.overall),
    );

    if log.candidates_extracted == 0 && !cli.report_only {
        all_issues.push(QualityIssue {
            severity: "info".into(), category: "card".into(),
            message: "候选概念为 0，卡片维度评分不可靠".into(),
        });
    }

    QualityEval {
        subject: log.subject.clone(),
        grade_band: log.grade_band.clone(),
        source_run_id: log.run_id.clone(),
        scores: QualityScores {
            teacher: Some(teacher),
            student,
            plan,
            card: Some(card),
            review,
            composite,
        },
        llm_eval_logs: all_llm_logs,
        issues: all_issues,
    }
}
