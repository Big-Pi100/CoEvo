//! CoEvo 概念提取评估 CLI
//!
//! 用法:
//!   cargo run --bin evaluate           # 跑全部 21 次测试
//!   cargo run --bin evaluate C01       # 单个用例
//!   cargo run --bin evaluate C01 A     # 用例 + 变体

use std::collections::HashMap;
use std::time::Instant;

use chat_engine::concept_extractor::{self, ConceptCandidate};
use chat_engine::llm_caller::LlmConfig;

// ===== 测试用例 =====

struct TestCase {
    id: &'static str,
    name: &'static str,
    #[allow(dead_code)]
    user_message: &'static str,
    ai_reply: &'static str,
    expected_fronts: &'static [&'static str],
    #[allow(dead_code)]
    domain: &'static str,
}

const TEST_CASES: &[TestCase] = &[
    TestCase {
        id: "C01", name: "物理 - 量子力学",
        user_message: "解释一下量子力学的基本概念",
        ai_reply: "量子力学是研究微观粒子运动规律的物理学分支。它的核心概念包括量子叠加态——微观粒子可以同时处于多个状态的叠加；波函数坍缩——测量时量子态从叠加态坍缩到某个本征态；以及海森堡不确定性原理——无法同时精确测量粒子的位置和动量。",
        expected_fronts: &["量子叠加态", "波函数坍缩", "不确定性原理"],
        domain: "physics",
    },
    TestCase {
        id: "C02", name: "英语故事 - The Little Seed",
        user_message: "给我讲个英语故事",
        ai_reply: "Once upon a time, there was a tiny seed. It lived deep in the dark soil. The seed felt small and lonely. It whispered, \"I want to see the sun.\" Days passed. Rain fell, and the sun warmed the ground. The seed began to grow. It pushed up through the soil. First, a tiny root went down. Then, a green sprout went up. A few useful words: seed (种子), soil (土壤), sprout (嫩芽), petals (花瓣), whisper (低语).",
        expected_fronts: &["种子萌发", "seed", "soil", "sprout", "whisper"],
        domain: "vocabulary",
    },
    TestCase {
        id: "C03", name: "历史 - 工业革命",
        user_message: "工业革命带来了什么影响",
        ai_reply: "工业革命始于18世纪中叶的英国，以蒸汽机的发明和广泛应用为标志。它带来了生产方式从手工业向机器大工业的转变，极大地提高了生产效率。同时，工业革命也促进了城市化进程，大量人口从农村迁移到城市。但同时也带来了环境污染、工人劳动条件恶化等问题。",
        expected_fronts: &["工业革命", "蒸汽机", "城市化"],
        domain: "history",
    },
    TestCase {
        id: "C04", name: "编程 - 二分查找",
        user_message: "解释二分查找算法",
        ai_reply: "Binary search is an efficient algorithm for finding a target value in a sorted array. It works by repeatedly dividing the search interval in half. First, compare the target value with the middle element. If they match, the search is done. If the target is less than the middle, continue searching in the left half. Time complexity is O(log n), making it much faster than linear search for large datasets.",
        expected_fronts: &["二分查找", "Binary search", "时间复杂度", "O(log n)"],
        domain: "tech",
    },
    TestCase {
        id: "C05", name: "学习方法论",
        user_message: "怎么才能高效学习",
        ai_reply: "高效学习的关键在于主动回忆和间隔重复。主动回忆是指在学习后主动尝试提取记忆，而不是被动重读。研究表明，主动回忆的效果是重读的 2-3 倍。间隔重复是指在遗忘曲线的最佳时间点进行复习，可以最大化记忆保持率。费曼技巧——用自己的话解释概念——也是验证理解程度的好方法。",
        expected_fronts: &["主动回忆", "间隔重复", "费曼技巧"],
        domain: "general",
    },
    TestCase {
        id: "D01", name: "直接制卡 - 光速",
        user_message: "帮我记住这个：光速是 3×10⁸ m/s",
        ai_reply: "光速（speed of light）在真空中是一个物理常数，约为每秒 3×10⁸ 米，记作 c。这是宇宙中信息传递的速度上限。",
        expected_fronts: &["光速"],
        domain: "physics",
    },
    TestCase {
        id: "D02", name: "英中混合 - AI 介绍",
        user_message: "tell me about machine learning",
        ai_reply: "Machine learning is a subset of artificial intelligence that enables systems to learn and improve from experience without being explicitly programmed. 机器学习有三大类型：监督学习（supervised learning）、无监督学习（unsupervised learning）和强化学习（reinforcement learning）。深度学习（deep learning）使用多层神经网络，在图像识别和自然语言处理领域取得了突破性进展。",
        expected_fronts: &["机器学习", "Machine learning", "监督学习", "Supervised learning", "深度学习", "Deep learning"],
        domain: "tech",
    },
];

// ===== Prompt 变体 =====

const PROMPT_VARIANTS: &[(&str, &str)] = &[
    ("A", "最多提取 5 个。如果没有值得提取的知识点，必须返回空数组 []。严禁返回没有意义的占位内容，不要编造概念。"),
    ("B", "没有数量限制。提取所有值得记住的知识点。如果没有，返回空数组 []。"),
    ("C", "提取值得记住的知识点，不设数量限制，但不要过度碎片化。每个知识点应有独立学习价值。front 必须简洁明确，不要用问句形式（如不要\"什么是XX？\"），直接用名词或短语。英文术语优先用中文+英文的形式，如\"量子叠加态 (Quantum superposition)\"。如果没有，返回空数组 []。"),
];

fn build_prompt(ai_reply: &str, variant_instruction: &str) -> String {
    format!(
        "从以下对话回复中，提取值得记住的知识点作为卡片。\n\n\
         要求：\n\
         - {}\n\
         - 每个元素必须是包含 front/back/source_sentence/domain 的 JSON 对象\n\
         - 只返回 JSON 数组，不要任何其他文字\n\n\
         回复: \"{}\"\n\n\
         JSON:", variant_instruction, ai_reply
    )
}

async fn run_extraction(
    config: &LlmConfig,
    ai_reply: &str,
    variant_instruction: &str,
) -> Vec<ConceptCandidate> {
    let prompt = build_prompt(ai_reply, variant_instruction);
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config.clone());
    match caller.generate(&prompt).await {
        Ok(text) => concept_extractor::parse_candidates(&text),
        Err(_) => vec![],
    }
}

#[derive(Default, Debug)]
struct EvalResult {
    concept_count: usize,
    elapsed_secs: f64,
    precision: f64,
    recall: f64,
    noise_rate: f64,
    has_vocab: bool,
}

fn evaluate(
    candidates: &[ConceptCandidate],
    test: &TestCase,
    elapsed_secs: f64,
) -> EvalResult {
    let mut r = EvalResult::default();
    r.concept_count = candidates.len();
    r.elapsed_secs = elapsed_secs;

    let expected = test.expected_fronts;
    let extracted_fronts: Vec<&str> = candidates.iter().map(|c| c.front.as_str()).collect();
    // matched: 有多少个 expected 被至少一个 candidate 匹配（子串匹配）
    let matched = expected.iter().filter(|e| {
        extracted_fronts.iter().any(|f| f.contains(*e) || e.contains(*f))
    }).count();
    // noised: 有多少个 candidate 没有匹配到任何 expected
    let noised = candidates.iter().filter(|c| {
        !expected.iter().any(|e| c.front.contains(e) || e.contains(&c.front))
    }).count();

    r.precision = if candidates.is_empty() { 0.0 } else { (matched as f64 / candidates.len() as f64).min(1.0) };
    r.recall = if expected.is_empty() { 1.0 } else { (matched as f64 / expected.len() as f64).min(1.0) };
    r.noise_rate = if candidates.is_empty() { 0.0 } else { noised as f64 / candidates.len() as f64 };

    // 检查是否有词汇匹配
    let matched_words = chat_engine::word_bank::match_text(test.ai_reply);
    r.has_vocab = !matched_words.is_empty();

    r
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let _ = dotenvy::dotenv();

    chat_engine::prompt_loader::init("prompts");
    chat_engine::word_bank::init("cefr_catalog.json");
    let config = chat_engine::config::load_llm_config();

    let args: Vec<String> = std::env::args().collect();
    let filter_id = args.get(1).map(|s| s.as_str());
    let filter_variant = args.get(2).map(|s| s.as_str());

    println!();
    println!("================================================================================");
    println!("  CoEvo 概念提取评估工具");
    println!("  用例: {} 个  变体: {} 种", TEST_CASES.len(), PROMPT_VARIANTS.len());
    println!("================================================================================");
    println!();

    let mut variant_map: HashMap<&'static str, Vec<EvalResult>> = HashMap::new();

    for test in TEST_CASES {
        if filter_id.is_some_and(|f| test.id != f) { continue; }

        for (vid, vinst) in PROMPT_VARIANTS {
            if filter_variant.is_some_and(|fv| *vid != fv) { continue; }

            println!("────────────────────────────────────────────────────────────────");
            println!("  {} | {} | 变体 {}", test.id, test.name, vid);
            println!("────────────────────────────────────────────────────────────────");

            let start = Instant::now();
            let candidates = run_extraction(&config, test.ai_reply, vinst).await;
            let elapsed = start.elapsed().as_secs_f64();

            let result = evaluate(&candidates, test, elapsed);

            for (i, c) in candidates.iter().enumerate() {
                let back = if c.back.chars().count() > 80 { format!("{}...", c.back.chars().take(80).collect::<String>()) } else { c.back.clone() };
                println!("  [{:2}] {} [{}]", i + 1, c.front, c.domain);
                println!("       {}", back);
            }

            if candidates.is_empty() {
                println!("  (空候选)");
            }

            // 词汇匹配
            let matched = chat_engine::word_bank::match_text(test.ai_reply);
            let existing: Vec<String> = candidates.iter().map(|c| c.front.to_lowercase()).collect();
            let new_vocab: Vec<&str> = matched.iter()
                .filter(|m| !existing.contains(&m.word.to_lowercase()))
                .map(|m| m.word.as_str())
                .collect();
            if !new_vocab.is_empty() {
                println!("  词汇匹配: {}", new_vocab.join(", "));
            }

            println!(
                "  候选: {} | 精准率: {:.0}% | 召回率: {:.0}% | 噪声率: {:.0}% | 耗时: {:.1}s\n",
                result.concept_count, result.precision * 100.0,
                result.recall * 100.0, result.noise_rate * 100.0, result.elapsed_secs
            );

            variant_map.entry(vid).or_default().push(result);
        }
    }

    // 汇总
    println!("================================================================================");
    println!("  汇总对比");
    println!("================================================================================");
    println!();
    println!("┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐");
    println!("│变体  │候选数│精准率│召回率│噪声率│空比率│耗时  │");
    println!("├──────┼──────┼──────┼──────┼──────┼──────┼──────┤");

    for (vid, results) in &variant_map {
        let n = results.len() as f64;
        let avg_concepts = results.iter().map(|r| r.concept_count).sum::<usize>() as f64 / n;
        let avg_p = results.iter().map(|r| r.precision).sum::<f64>() / n;
        let avg_r = results.iter().map(|r| r.recall).sum::<f64>() / n;
        let avg_noise = results.iter().map(|r| r.noise_rate).sum::<f64>() / n;
        let empty_count = results.iter().filter(|r| r.concept_count == 0).count();
        let avg_t = results.iter().map(|r| r.elapsed_secs).sum::<f64>() / n;

        println!("│ {:<4} │ {:4.1} │ {:4.0}% │ {:4.0}% │ {:4.0}% │ {}/{}  │ {:4.1}s │",
            vid, avg_concepts, avg_p * 100.0, avg_r * 100.0, avg_noise * 100.0,
            empty_count, results.len(), avg_t);
    }

    println!("└──────┴──────┴──────┴──────┴──────┴──────┴──────┘");
    println!();
}
