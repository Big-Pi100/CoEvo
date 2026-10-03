//! 🔴 **内容质量闸门的全量复跑工具**（2026-10-03 新增）
//!
//! # 它回答什么
//!
//! 1. 新判据在**生产全量内容**上拦了哪些？（要能逐条看到 id / 原因 / 标题）
//! 2. **有没有误杀**？（正常英语文章一篇都不能被拦）
//! 3. **安全边际**在哪？（临界样本 —— 最接近阈值的那些）
//!
//! # 为什么必须用它（而不是「写单测就够了」）
//!
//! 📌 判据：**「阈值标定」必须在全量真实数据上做，不能用几个手编样本替代**。
//!    上一轮就是「用几个样本验证 ⇒ 得出『临界样本为空』的结论」——
//!    而那个结论建立在**错误的分母**上（越南语字符被整个忽略），
//!    全量数据一跑就会暴露。
//!
//! # 用法
//!
//! ```bash
//! cd backend
//! # 摘要（推荐）：拦截清单 + 临界样本 + 安全边际
//! cargo run --release --example gate_replay
//!
//! # 全量 TSV（写单测断言时用来取真实数字）
//! cargo run --release --example gate_replay -- --tsv > /tmp/gate_replay.tsv
//! ```
//!
//! # 🔴 数据来源必须可追溯
//!
//! 输入 fixture 由 `scripts/trace_verify/bin/dump_prod_content.py` **只读**导出：
//! ```bash
//! ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" \
//!     < scripts/trace_verify/bin/dump_prod_content.py \
//!     > scripts/trace_verify/fixtures/prod_content_all.json
//! ```
//! ⇒ 「哪一天、从哪个库、多少条」都能复现，而不是「我记得当时是 966 条」。

use api_server::content_quality::{check_content, count_letters, english_word_stats};

/// 生产实测的 6 条非英语内容（2026-10-03）—— 新判据必须**全部**拦下。
const MUST_REJECT: &[i64] = &[8, 737, 1021, 1645, 2032, 4260];

#[derive(Debug)]
struct Row {
    id: i64,
    title: String,
    letters: usize,
    eng_chars: usize,
    tokens: usize,
    hits: usize,
    reject: Option<String>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let tsv = args.iter().any(|a| a == "--tsv");
    let path = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with("--"))
        .cloned()
        .unwrap_or_else(|| "../scripts/trace_verify/fixtures/prod_content_all.json".to_string());

    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "读 fixture 失败（{path}）: {e}\n\
             💡 先用 dump_prod_content.py 从生产库导出"
        )
    });
    let rows: Vec<serde_json::Value> = serde_json::from_str(&raw)
        .expect("解析 JSON 失败（应是 [{id,src,title,summary,body,url}, ...]）");

    let mut out: Vec<Row> = Vec::with_capacity(rows.len());
    let mut n_no_body = 0usize;

    for r in &rows {
        let id = r["id"].as_i64().unwrap_or(0);
        let title = r["title"].as_str().unwrap_or("");
        let body = r["body"].as_str().unwrap_or("");
        let summary = r["summary"].as_str().unwrap_or("");
        let url = r["url"].as_str().unwrap_or("");

        // 🔑 复刻 `content_fetch::write_items` 的取文本逻辑：
        //    `it.body.as_deref().or(it.summary.as_deref()).unwrap_or("")`
        //    ⚠️ JSON 里无法区分 `body = None` 与 `body = Some("")`，
        //       所以这里用「**非空**才优先用 body」—— 与严格 `or()` 有一处差异：
        //       严格 `or()` 在 `body = Some("")` 时**不会**退回 summary ⇒ 会绕过判据。
        //       📌 这是复跑工具与生产实现之间**唯一的已知口径差**，
        //          已作为「附带发现」写进报告（内容侧的空串 fallback 问题）。
        let gate_text = if !body.trim().is_empty() {
            body
        } else {
            n_no_body += 1;
            summary
        };
        let all = format!("{}\n{}", title, gate_text);

        let (letters, eng_chars) = count_letters(&all);
        let (tokens, hits) = english_word_stats(&all);
        let reject = check_content(title, gate_text, url).map(|r| r.to_string());

        out.push(Row {
            id,
            title: title.to_string(),
            letters,
            eng_chars,
            tokens,
            hits,
            reject,
        });
    }

    if tsv {
        println!("id\tletters\teng_chars\teng_pct\ttokens\thits\tword_pct\tverdict\tcriteria");
        for r in &out {
            let eng_pct = if r.letters == 0 {
                0.0
            } else {
                100.0 * r.eng_chars as f64 / r.letters as f64
            };
            let word_pct = if r.tokens == 0 {
                0.0
            } else {
                100.0 * r.hits as f64 / r.tokens as f64
            };
            println!(
                "{}\t{}\t{}\t{:.2}\t{}\t{}\t{:.2}\t{}\t{}",
                r.id,
                r.letters,
                r.eng_chars,
                eng_pct,
                r.tokens,
                r.hits,
                word_pct,
                if r.reject.is_some() { "REJECT" } else { "keep" },
                r.reject.clone().unwrap_or_default()
            );
        }
        eprintln!("tsv 模式：{} 行已输出（stdout）", out.len());
        return;
    }

    // ── 摘要模式 ──
    println!("fixture: {path}");
    println!(
        "总条数: {}（其中 {} 条 body 为空、退化为 summary）",
        out.len(),
        n_no_body
    );
    println!();

    let rejected: Vec<&Row> = out.iter().filter(|r| r.reject.is_some()).collect();
    println!("=== 🔴 被拦条目（{} 条）===", rejected.len());
    for r in &rejected {
        let t: String = r.title.chars().take(58).collect();
        println!("  id={:<5} {:<34} {}", r.id, r.reject.clone().unwrap(), t);
    }

    let must_set: std::collections::HashSet<i64> = MUST_REJECT.iter().copied().collect();
    let present: std::collections::HashSet<i64> = out.iter().map(|r| r.id).collect();
    let got: std::collections::HashSet<i64> = rejected.iter().map(|r| r.id).collect();
    // ⚠️ 只在「该 id **当前还在库里**」时才要求「必须被拦」——
    //    因为这 6 条已于 2026-10-03 从生产库删除，fixture 更新后它们就不在数据里了。
    //    若不区分，会误报「漏拦 6 条」（❌ 假红）。
    let missed: Vec<i64> = MUST_REJECT
        .iter()
        .copied()
        .filter(|i| present.contains(i) && !got.contains(i))
        .collect();
    let absent: Vec<i64> = MUST_REJECT
        .iter()
        .copied()
        .filter(|i| !present.contains(i))
        .collect();
    let extra: Vec<i64> = got
        .iter()
        .copied()
        .filter(|i| !must_set.contains(i))
        .collect();

    println!();
    println!("=== 判定 ===");
    println!(
        "  6 条已知非英语: {}{}",
        if missed.is_empty() {
            "全部拦下 ✅".to_string()
        } else {
            format!("🔴 漏拦 {missed:?}")
        },
        if absent.is_empty() {
            String::new()
        } else {
            format!("（其中 {absent:?} 已不在库中 —— 已于 2026-10-03 删除，不参与判定）")
        }
    );
    println!(
        "  非预期命中（疑似误杀 / 可能还有别的非英语）: {}",
        if extra.is_empty() {
            "无 ✅".to_string()
        } else {
            format!("⚠️ {extra:?}（见下表逐条核对）")
        }
    );

    // ── 逐条核对「非预期命中」的原文特征 ──
    for r in &rejected {
        if must_set.contains(&r.id) {
            continue;
        }
        let eng_pct = if r.letters == 0 {
            0.0
        } else {
            100.0 * r.eng_chars as f64 / r.letters as f64
        };
        let word_pct = if r.tokens == 0 {
            0.0
        } else {
            100.0 * r.hits as f64 / r.tokens as f64
        };
        let t: String = r.title.chars().take(58).collect();
        println!(
            "    ⚠️ id={} 英语字符 {:.1}% ({}/{}) · 功能词 {:.1}% ({}/{}) · {t}",
            r.id, eng_pct, r.eng_chars, r.letters, word_pct, r.hits, r.tokens
        );
    }

    // ── 临界样本：**通过**的条目里最接近阈值的 ──
    let mut kept: Vec<&Row> = out.iter().filter(|r| r.reject.is_none()).collect();

    println!();
    println!("=== 临界样本 · 保留条目里英语字符占比最低的 8 条（阈值 90%）===");
    kept.sort_by(|a, b| {
        let ra = if a.letters == 0 {
            1.0
        } else {
            a.eng_chars as f64 / a.letters as f64
        };
        let rb = if b.letters == 0 {
            1.0
        } else {
            b.eng_chars as f64 / b.letters as f64
        };
        ra.partial_cmp(&rb).unwrap()
    });
    let mut shown = 0;
    for r in &kept {
        if r.letters < 50 {
            continue; // 不判的条目不算临界样本
        }
        let pct = 100.0 * r.eng_chars as f64 / r.letters as f64;
        let t: String = r.title.chars().take(52).collect();
        println!("  {:.2}%  (字母 {})  id={:<5} {t}", pct, r.letters, r.id);
        shown += 1;
        if shown >= 8 {
            break;
        }
    }

    println!();
    println!("=== 临界样本 · 保留条目里功能词密度最低的 8 条（阈值 8%）===");
    kept.sort_by(|a, b| {
        let ra = if a.tokens == 0 {
            1.0
        } else {
            a.hits as f64 / a.tokens as f64
        };
        let rb = if b.tokens == 0 {
            1.0
        } else {
            b.hits as f64 / b.tokens as f64
        };
        ra.partial_cmp(&rb).unwrap()
    });
    let mut shown = 0;
    for r in &kept {
        if r.tokens < 30 {
            continue; // 不判的条目不算临界样本
        }
        let pct = 100.0 * r.hits as f64 / r.tokens as f64;
        let t: String = r.title.chars().take(52).collect();
        println!("  {:.2}%  (词 {})  id={:<5} {t}", pct, r.tokens, r.id);
        shown += 1;
        if shown >= 8 {
            break;
        }
    }

    // ── 覆盖率：多少条**两条判据都判不了** ──
    let c_skip = out.iter().filter(|r| r.letters < 50).count();
    let d_skip = out.iter().filter(|r| r.tokens < 30).count();
    let both_skip = out
        .iter()
        .filter(|r| r.letters < 50 && r.tokens < 30)
        .count();
    println!();
    println!("=== 判据覆盖率（分母 = {}）===", out.len());
    println!("  C 判据（需字母 ≥ 50）不判: {c_skip} 条");
    println!("  D 判据（需词 ≥ 30）不判: {d_skip} 条");
    println!("  两条都不判（= 无语言把关）: {both_skip} 条  ← ⚠️ 这是真实漏拦面");
}
