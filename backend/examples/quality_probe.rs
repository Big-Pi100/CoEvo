//! 🔴 调查工具（2026-10-03）：用**生产真实文本**跑闸门的语言判据。
//!
//! > ⚠️ **本工具是「当时的证据固定」** —— 它记录的「旧口径 vs 新口径」差异
//! > 已在 `content_quality.rs` 里修复（补区间表 + 新增词汇判据）。
//! > **全量回归请用 `examples/gate_replay.rs`**（本工具只诊断**单份文本**）。
//!
//! # 它当时回答的问题
//!
//! 白哥报「一篇含大量非英文字符的文章没被过滤」。
//! 我用 Python 复刻算了拉丁占比 = 86.9%（< 阈值 90% ⇒ 该拦），
//! 但它在库里 ⇒ **矛盾**。
//!
//! # 🔑 根因（已确认）
//!
//! `is_letter` / `is_latin` 的**覆盖面**里**没有** Latin Extended Additional
//! （`U+1E00–U+1EFF`）—— 而**越南语**的声调字母（`ạ ả ấ ầ ệ ị ọ ụ ứ ỳ`）全在那里。
//! ⇒ 那些字符**既不入分子也不入分母**（被完全忽略）
//! ⇒ 分母只剩 ASCII + 拉丁扩展 A/B ⇒ **占比虚高到 100%** ⇒ 放过。
//!
//! 而我用 Python 的 `str.isalpha()`（**全 Unicode 字母**）复刻 ⇒ 分母包含它们 ⇒ 86.9%。
//! 📌 **这就是「跨实现不一致」**：我明明在注释里写了「两处必须一致」，
//!    却只对齐了**阈值**，没对齐**字母判定表**。
//!
//! ✅ 修复后：区间表已补全，本工具的两个口径**分母相同**（差异列应显示 0）。
//!
//! # 用法（**必须用 CI 同款 Rust**）
//!
//! ```bash
//! cd backend
//! # 从生产库导出：SELECT id, title, body FROM content_pool WHERE id=4260
//! cargo run --release --example quality_probe -- <文本文件路径>
//! ```
//!
//! # 判据
//!
//! 输出**两种算法**的占比并对比：
//! · `gate`  = 生产实现（`content_quality::count_letters`）—— **权威**
//! · `unicode_all` = 全 Unicode 字母（`char::is_alphabetic`）—— 我 Python 复刻的口径
//!
//! 若两者差异显著 ⇒ 确认根因是「字母判定表覆盖面」，而非阈值。

use std::fs;

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("用法: quality_probe <文本文件路径>");

    let text = fs::read_to_string(&path).expect("读文件失败");
    println!("文件: {}  ({} 字符)", path, text.chars().count());

    // ── ① 生产实现（权威）──
    let (letters, latin) = api_server::content_quality::count_letters(&text);
    let gate_ratio = if letters == 0 {
        0.0
    } else {
        latin as f64 / letters as f64
    };

    // ── ② 全 Unicode 字母口径（我 Python/Dart 复刻用的）──
    let uni_letters = text.chars().filter(|c| c.is_alphabetic()).count();
    let uni_latin = text
        .chars()
        .filter(|c| {
            let u = *c as u32;
            c.is_alphabetic()
                && ((0x0041..=0x005A).contains(&u)
                    || (0x0061..=0x007A).contains(&u)
                    || (0x00C0..=0x024F).contains(&u))
        })
        .count();
    let uni_ratio = if uni_letters == 0 {
        0.0
    } else {
        uni_latin as f64 / uni_letters as f64
    };

    println!();
    println!("=== 两种「分母口径」的对比 ===");
    println!("  ① 生产闸门 (count_letters):");
    println!(
        "       字母={letters}  拉丁={latin}  ⇒ {:.2}%",
        100.0 * gate_ratio
    );
    println!("  ② 全 Unicode (is_alphabetic):");
    println!(
        "       字母={uni_letters}  拉丁={uni_latin}  ⇒ {:.2}%",
        100.0 * uni_ratio
    );
    println!();
    println!(
        "  被忽略的字符数（两者分母之差）: {}",
        uni_letters as i64 - letters as i64
    );
    println!(
        "  ⇒ 闸门判定: {}",
        if letters < 50 {
            "⬜ 放过（字母太少，MIN_LETTERS 保护）".to_string()
        } else if gate_ratio < 0.90 {
            "🔴 拦截".to_string()
        } else {
            "⬜ 放过（占比 ≥ 90%）".to_string()
        }
    );
    println!(
        "  ⇒ 若用全 Unicode 口径: {}",
        if uni_letters < 50 {
            "⬜ 放过（字母太少）".to_string()
        } else if uni_ratio < 0.90 {
            "🔴 拦截".to_string()
        } else {
            "⬜ 放过（占比 ≥ 90%）".to_string()
        }
    );

    // ── ③ 字符分布（看落在哪）──
    println!();
    println!("=== 字符区间分布（非 ASCII 部分）===");
    let mut buckets: std::collections::BTreeMap<&str, usize> = Default::default();
    for c in text.chars() {
        let u = c as u32;
        if u < 0x80 {
            continue;
        }
        let name = if (0x0080..=0x00FF).contains(&u) {
            "Latin-1 补充"
        } else if (0x0100..=0x017F).contains(&u) {
            "拉丁扩展 A"
        } else if (0x0180..=0x024F).contains(&u) {
            "拉丁扩展 B"
        } else if (0x1E00..=0x1EFF).contains(&u) {
            "🔴 拉丁扩展附加 (U+1E00–1EFF) ← 越南语在此"
        } else if (0x0300..=0x036F).contains(&u) {
            "组合变音符号"
        } else if (0x2000..=0x206F).contains(&u) {
            "通用标点"
        } else if (0x4E00..=0x9FFF).contains(&u) {
            "CJK"
        } else {
            "其他"
        };
        *buckets.entry(name).or_insert(0) += 1;
    }
    for (k, v) in &buckets {
        println!("  {k:<44} {v}");
    }
}
