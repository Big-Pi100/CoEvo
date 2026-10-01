//! 正文抓取诊断 —— 对给定 URL 打印**每一步**的结果。
//!
//! ```bash
//! cd backend
//! cargo run --example body_diag -- <url>
//! ```
//!
//! # 为什么需要它
//! `content_probe --diag` 只告诉你「这个源没抓到正文」，**不告诉你卡在哪一步**：
//! · HTTP 就没通？（网络/UA/超时）
//! · 通了但提取 0 段？（选择器/负面标记误伤）
//! · 提取到了但判为太短？（阈值）
//!
//! 三种原因的修法完全不同 → 必须能分辨。这正是「**先让失败可分辨，再谈修**」。

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(url) = args.get(1) else {
        eprintln!("用法: cargo run --example body_diag -- <url>");
        std::process::exit(2);
    };

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("建 runtime 失败");

    println!("── 正文抓取诊断 ──");
    println!("URL: {}", url);
    println!();

    // ── 步骤 1：HTTP ──
    //
    // 🔑 用 `api_server` 暴露的抓取函数，**不自己建 reqwest client** ——
    //    `reqwest` 是 `api_server` 的依赖，例程 crate 里**用不到**（实测报 E0433）。
    //    更重要的是：自己建一份就成了**第二份实现**，
    //    诊断的和我实际跑的路径不同 → 诊断结论**不适用**。
    //    （同 `migrate_probe` 复用 `db_pool::init` 的理由。）
    println!("【1】HTTP + 提取（走**生产同一条**代码路径）");
    let outcome = rt.block_on(api_server::content_fetch::fetch_article_body_diagnostic(
        url,
    ));
    match &outcome {
        api_server::content_fetch::BodyOutcome::Got(text) => {
            let paras: Vec<&str> = text.split("\n\n").collect();
            println!("  ✅ 采纳为正文");
            println!(
                "  段数 {} · 总长 {} 字符",
                paras.len(),
                text.chars().count()
            );
            for (i, p) in paras.iter().take(5).enumerate() {
                println!(
                    "    [{}] ({:>5}) {}",
                    i,
                    p.chars().count(),
                    p.chars().take(110).collect::<String>()
                );
            }
            if paras.len() > 5 {
                println!("    … 还有 {} 段", paras.len() - 5);
            }
            println!();
            println!("✅ 这条路能抓到正文 —— 若批量抓取仍失败，问题在**队列/DB**层，不在这里");
        }
        api_server::content_fetch::BodyOutcome::HttpFailed(e) => {
            println!("  🔴 HTTP 失败：{}", e);
            println!();
            println!("  → 下一步：查网络 / UA / 超时 / 对方是否防爬。");
            println!("    🔑 这一类**与提取逻辑无关**，改选择器没用。");
        }
        api_server::content_fetch::BodyOutcome::NoParagraphs => {
            println!("  🔴 HTTP 通了，但**一段正文都没提取到**");
            println!();
            println!("  → 下一步：查选择器是否匹配、负面标记是否把正文整块排除了。");
            println!("    可用 `--dump` 把 HTML 存下来人工看结构。");
        }
        api_server::content_fetch::BodyOutcome::TooShort(len) => {
            println!("  🔴 提取到了但太短（{} < 300 字符）→ 判为「没提到」", len);
            println!();
            println!("  → 下一步：看清是不是「cookie 横幅 + 一句导航」被误当正文；");
            println!("    若确实是短讯，考虑调低阈值（但有把噪音当正文的风险）。");
        }
    }
}
