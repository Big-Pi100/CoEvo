//! 候选内容源评估 —— 回答「**可达性**」与「**抓取质量**」两个问题。
//!
//! # 🔴 为什么是 example 而不是 Python 脚本
//!
//! 评估「这个源能不能用」必须走**真实的那条代码路径**：
//! · RSS 侧 → [`fetch_source_items`]（真的 `parse_rss` + `classify_encoded`）
//! · 网页侧 → [`fetch_article_body_diagnostic`]（真的 `dom_smoothie` 提取）
//!
//! 自己拿 Python 复刻一遍会引入偏差 —— 本次 Ars 的教训正是：
//! 我用 Python 剥 `<description>` 时把 CDATA 一起剥了，得出「description 是空的」，
//! **而真相是 14 词导读**（工具错导致反向结论）。
//!
//! # 📌 三项质量判据（都是踩出来的）
//!
//! | 判据 | 怎么来的 |
//! |---|---|
//! | **≥300 词**才算可读长文 | Ars 因此被废弃（32/33 条 <300 词）|
//! | **句末完整**（不是半句）| Ars 的探针：当时 **0/33** 篇完整 |
//! | 🆕 **营销内容占比** | Wired 实测 **21/50 是「优惠码」页**（2026-10-02 新增）|
//!
//! # ⚠️ 只读
//!
//! 不碰任何数据库。只发 HTTP 请求 + 打印统计。
//!
//! ```bash
//! cd backend
//! cargo run -q -p api_server --example eval_candidate_sources
//! ```

use api_server::content_fetch::{
    fetch_article_body_diagnostic, fetch_source_items, BodyOutcome, SourceRow,
};
use api_server::content_rss::ParsedItem;

/// 每个源测几篇网页提取（控制总耗时：每篇 1–10 s）。
const SAMPLE_PER_SOURCE: usize = 4;

/// 正文至少这么多词才算「可读的长文」。与后端 `MIN_FULL_BODY_WORDS` 同口径。
const READABLE_WORDS: usize = 300;

struct Candidate {
    name: &'static str,
    url: &'static str,
    /// Atom 源后端**解析不了**（`parse_rss` 只认 RSS 2.0）—— 提前标出，避免误判成「抓取失败」。
    atom: bool,
    role: &'static str,
}

const CANDIDATES: &[Candidate] = &[
    // ── 待接入：NPR 6 个分频道（补「其他类型不够」）──
    Candidate {
        name: "NPR World",
        url: "https://feeds.npr.org/1004/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "NPR Business",
        url: "https://feeds.npr.org/1006/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "NPR Science",
        url: "https://feeds.npr.org/1007/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "NPR Culture",
        url: "https://feeds.npr.org/1008/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "NPR Technology",
        url: "https://feeds.npr.org/1019/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "NPR Health",
        url: "https://feeds.npr.org/1128/rss.xml",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "arXiv cs.CL",
        url: "https://export.arxiv.org/rss/cs.CL",
        atom: false,
        role: "拟接入",
    },
    Candidate {
        name: "HackerNoon",
        url: "https://hackernoon.com/feed",
        atom: false,
        role: "拟接入",
    },
    // ── 对照组：现有源，确认「新源与老源同构」──
    Candidate {
        name: "NPR News(现有)",
        url: "https://feeds.npr.org/1001/rss.xml",
        atom: false,
        role: "对照",
    },
];

/// 营销页标题的特征词（优惠码 / 促销）。
///
/// 🔑 **只在标题上匹配** —— 实测 Wired 的营销页 URL 在 `/story/` 下，
///    与真新闻**同路径**（`/story/columbia-promo-code/`），URL 无法区分。
const PROMO_TITLE_WORDS: &[&str] = &[
    "promo code",
    "promo codes",
    "coupon",
    "coupons",
    "% off",
    "discount code",
];

/// 导购/评测类（**不算营销页**，但话题偏消费，单独计）。
const SHOPPING_TITLE_WORDS: &[&str] = &["best ", "deal", "deals", "review", "gift"];

fn words(s: &str) -> usize {
    s.split_whitespace().filter(|w| !w.is_empty()).count()
}

fn tail(s: &str, n: usize) -> String {
    let v: Vec<char> = s.chars().collect();
    let start = v.len().saturating_sub(n);
    v[start..].iter().collect()
}

/// 正文是否以句末标点收尾 —— Ars 那个「0/33 完整结尾」的探针。
fn ends_sentence(s: &str) -> bool {
    matches!(
        s.trim_end().chars().last(),
        Some('.') | Some('!') | Some('?') | Some('"') | Some('”') | Some(')') | Some('…')
    )
}

fn classify_title(t: &str) -> &'static str {
    let low = t.to_lowercase();
    if PROMO_TITLE_WORDS.iter().any(|k| low.contains(k)) {
        "🛒营销"
    } else if SHOPPING_TITLE_WORDS.iter().any(|k| low.contains(k)) {
        "🛍导购"
    } else {
        "📰内容"
    }
}

#[tokio::main]
async fn main() {
    println!("{}", "═".repeat(100));
    println!("候选内容源评估 —— 真实抓取 + 真实提取（dom_smoothie）");
    println!("{}", "═".repeat(100));

    let mut summary: Vec<(String, String, String)> = Vec::new();

    for c in CANDIDATES {
        println!("\n{}", "─".repeat(100));
        println!("【{}】{}  {}", c.role, c.name, c.url);
        println!("{}", "─".repeat(100));

        let src = SourceRow {
            id: -1,
            name: c.name.to_string(),
            url: c.url.to_string(),
            kind: "rss".to_string(),
            category: None,
            redistributable: 1,
            tz_offset_min: 0,
        };

        let t0 = std::time::Instant::now();
        let items = match fetch_source_items(&src).await {
            Ok(v) => v,
            Err(e) => {
                let hint = if c.atom {
                    "（预期：Atom 源，后端只解析 RSS 2.0）"
                } else {
                    ""
                };
                println!("  🔴 RSS 失败: {} {}", e, hint);
                summary.push((
                    c.name.to_string(),
                    format!("🔴 {}", e.chars().take(26).collect::<String>()),
                    "—".to_string(),
                ));
                continue;
            }
        };
        let rss_ms = t0.elapsed().as_millis();

        // ── ① RSS 层 ──
        let with_body: Vec<&ParsedItem> = items.iter().filter(|i| i.body.is_some()).collect();
        let sum_only: Vec<&ParsedItem> = items
            .iter()
            .filter(|i| i.body.is_none() && i.summary.is_some())
            .collect();
        let neither = items.len() - with_body.len() - sum_only.len();

        // 🆕 营销内容占比（标题判据）
        let promo = items
            .iter()
            .filter(|i| classify_title(&i.title) == "🛒营销")
            .count();
        let shopping = items
            .iter()
            .filter(|i| classify_title(&i.title) == "🛍导购")
            .count();
        let real = items.len() - promo - shopping;

        println!("  ① RSS: ✅ {} 条 · {} ms", items.len(), rss_ms);
        println!(
            "     内容构成: 📰内容 {} · 🛍导购 {} · 🛒营销 {}  ← 🔑 营销页对学英语无价值",
            real, shopping, promo
        );

        let mut sw: Vec<usize> = sum_only
            .iter()
            .filter_map(|i| i.summary.as_deref())
            .map(words)
            .collect();
        sw.sort_unstable();
        let bw: Vec<usize> = {
            let mut v: Vec<usize> = with_body
                .iter()
                .filter_map(|i| i.body.as_deref())
                .map(words)
                .collect();
            v.sort_unstable();
            v
        };
        let med = |v: &[usize]| v.get(v.len() / 2).copied().unwrap_or(0);
        println!(
            "     RSS 给全文: {} 条{} · 仅摘要: {} 条（中位 {} 词，范围 {}–{}）{}",
            with_body.len(),
            if bw.is_empty() {
                String::new()
            } else {
                format!("（中位 {} 词）", med(&bw))
            },
            sum_only.len(),
            med(&sw),
            sw.first().copied().unwrap_or(0),
            sw.last().copied().unwrap_or(0),
            if neither > 0 {
                format!(" · 🔴 无摘要无正文 {} 条", neither)
            } else {
                String::new()
            }
        );

        // ── ② 网页提取层 ──
        let need_fetch: Vec<&ParsedItem> = if with_body.len() == items.len() {
            Vec::new()
        } else {
            items
                .iter()
                .filter(|i| i.body.is_none())
                // 🔑 营销页**不参与质量评估** —— 它们本来就不该入库
                .filter(|i| classify_title(&i.title) != "🛒营销")
                .take(SAMPLE_PER_SOURCE)
                .collect()
        };

        if need_fetch.is_empty() {
            println!("\n  ② 网页提取: ⏭️ 跳过 —— RSS 已给全部条目的全文");
            summary.push((
                c.name.to_string(),
                format!(
                    "{} 条 · **RSS 全文**中位 {} 词 · 内容 {}",
                    items.len(),
                    med(&bw),
                    real
                ),
                "无需抓网页".to_string(),
            ));
            continue;
        }

        println!(
            "\n  ② 网页提取（真实 dom_smoothie · 抽 {} 篇，已排除营销页）:",
            need_fetch.len()
        );
        let mut got: Vec<(usize, bool)> = Vec::new();
        let mut fails = 0usize;
        for it in &need_fetch {
            match fetch_article_body_diagnostic(&it.url).await {
                BodyOutcome::Got(md) => {
                    let w = words(&md);
                    let ok = ends_sentence(&md);
                    println!(
                        "       ✅ {:>5} 词 · 句末{} · {}",
                        w,
                        if ok { "完整" } else { "🔴截断" },
                        it.title.chars().take(46).collect::<String>()
                    );
                    if !ok {
                        println!("          尾: …{}", tail(&md, 84).replace('\n', "⏎"));
                    }
                    got.push((w, ok));
                }
                BodyOutcome::HttpFailed(e) => {
                    fails += 1;
                    println!(
                        "       🔴 失败: {} ← {}",
                        e.chars().take(46).collect::<String>(),
                        it.title.chars().take(36).collect::<String>()
                    );
                }
                BodyOutcome::NoParagraphs => {
                    fails += 1;
                    println!(
                        "       🔴 提取为空 ← {}",
                        it.title.chars().take(44).collect::<String>()
                    );
                }
                BodyOutcome::TooShort(n) => {
                    fails += 1;
                    println!(
                        "       🟡 太短({} 字符) ← {}",
                        n,
                        it.title.chars().take(40).collect::<String>()
                    );
                }
            }
        }
        let readable = got.iter().filter(|(w, _)| *w >= READABLE_WORDS).count();
        let complete = got.iter().filter(|(_, ok)| *ok).count();
        println!(
            "      → 成功 {} · ≥{} 词 {} 篇 · 句末完整 {} 篇 · 失败 {}",
            got.len(),
            READABLE_WORDS,
            readable,
            complete,
            fails
        );

        // 可用内容量：只算「非营销」条目 × 达标率 × 4 轮
        let ratio = if need_fetch.is_empty() {
            0.0
        } else {
            readable as f64 / need_fetch.len() as f64
        };
        let per_day = ((items.len() - promo) as f64 * ratio * 4.0).round() as usize;
        summary.push((
            c.name.to_string(),
            format!(
                "{} 条 · 营销 {} · 摘要中位 {} 词",
                items.len(),
                promo,
                med(&sw)
            ),
            format!(
                "{}/{} 达标 · 日增约 {} 条",
                readable,
                need_fetch.len(),
                per_day
            ),
        ));
    }

    println!("\n{}", "═".repeat(100));
    println!("【汇总】");
    println!("{}", "═".repeat(100));
    println!("  {:<18} {:<44} 网页提取", "源", "RSS 层");
    println!("  {}", "-".repeat(96));
    for (n, r, w) in &summary {
        println!("  {:<18} {:<44} {}", n, r, w);
    }
    println!();
    println!("  判据：≥{} 词为可读长文；「句末完整」是 Ars 探针（当时 0/33）；营销页 = 标题含 promo/coupon/% off。", READABLE_WORDS);
}
