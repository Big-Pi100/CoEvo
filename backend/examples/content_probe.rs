//! 内容抓取冒烟工具 —— 在一个**临时库**上真跑一遍「抓取 + 入库」。
//!
//! # 用法
//!
//! ```bash
//! cd backend
//! cargo run --example content_probe                 # 用临时库（推荐）
//! cargo run --example content_probe -- <db-path>    # 指定库（会写它！）
//! ```
//!
//! # 🔴 为什么需要它（而不是「跑单测就够了」）
//!
//! 单测覆盖的是**解析语义**（用抓下来的 fixture）与**入库幂等**（内存库）。
//! 它们验证不了「**真的去网上抓，真的能落库**」这一环 ——
//! 而那正是「内容源」这条线**唯一无法靠断言代替**的部分：
//! · 源站今天可达吗？会不会因为我们没带 UA 而 403？
//! · 响应还是 RSS 2.0 吗？字段有没有变？
//! · HN 的 item 结构变了吗？
//!
//! 🔑 判据：**「解析对」与「抓得到」是两层** —— fixture 全绿只能证明前者。
//!    本工具补后者。
//!
//! # 行为
//! · 默认建**临时库**（`%TEMP%/coevo_content_probe.db`）→ 不碰任何现有库
//! · 真抓一**轮**（5 个源）→ 打印逐源结果 + 落库统计
//! · 退出码：有源成功 = 0；**全部失败 = 1**（便于 CI / 脚本判断）
//!   ⚠️ 部分失败**不算失败** —— 单个源挂掉是正常运维状态（见 `fetch_all` 的说明）。

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // 🆕 诊断模式：每个源各挑 1 条**实际去抓正文**并打印结果
    //   —— 用来定位「某源的页面为什么抓不到正文」
    //   跑法：cargo run --example content_probe -- --diag
    let diag = args.iter().any(|a| a == "--diag");
    let path = match args.iter().find(|a| !a.starts_with("--") && *a != &args[0]) {
        Some(p) => p.clone(),
        None => {
            let dir = std::env::temp_dir();
            dir.join("coevo_content_probe.db")
                .to_string_lossy()
                .to_string()
        }
    };
    // 🔴 每次从干净库开始 —— 否则上一轮的数据会让「新增 0 条」看不出是幂等还是没抓到
    let _ = std::fs::remove_file(&path);

    println!("── 内容抓取冒烟 ──");
    println!("临时库: {}", path);
    println!();

    if let Err(e) = api_server::db_pool::init(&path) {
        eprintln!("🔴 建库/迁移失败: {}", e);
        std::process::exit(1);
    }
    println!("✅ 建库完成（含 content_source / content_pool + 种子源）");
    println!();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("建 runtime 失败");

    let now = api_server::content_fetch::now_utc_iso();
    println!("开始抓取（真实网络 · 5 个源）…");
    let outcomes = rt.block_on(api_server::content_fetch::fetch_all(&now));

    println!();
    println!("── 逐源结果 ──");
    let mut ok_count = 0;
    for o in &outcomes {
        match &o.error {
            None => {
                ok_count += 1;
                println!(
                    "  ✅ {:<22} 拿到 {:>3} 条 · 新增 {:>3} 条",
                    o.source_name, o.items, o.inserted
                );
            }
            Some(e) => println!("  🔴 {:<22} {}", o.source_name, e),
        }
    }

    // 落库统计（直接查库核对，不只看抓取器的自述）
    println!();
    println!("── 补抓正文（RSS 通常只给摘要 → 抓原网页）──");
    if diag {
        println!("🔍 诊断模式：每个源各取 1 条，实际抓取并打印提取结果");
    }
    println!(
        "开始补抓（真实网络 · 每轮最多 {} 篇）…",
        api_server::content_fetch::MAX_BODY_FETCH_PER_ROUND
    );
    let (tried, got) = rt.block_on(api_server::content_fetch::fetch_bodies_round());
    println!("  尝试 {} 篇 · 成功 {} 篇", tried, got);

    if diag {
        println!();
        println!("── 🔍 逐源诊断（每源 1 条）──");
        let conn = api_server::db_pool::get_conn();
        let mut stmt = conn
            .prepare(
                "SELECT s.name, p.url, \
                        CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END, \
                        COALESCE(LENGTH(p.body), 0) \
                 FROM content_source s \
                 JOIN content_pool p ON p.source_id = s.id \
                 WHERE p.body_attempted_at IS NOT NULL \
                 GROUP BY s.id ORDER BY s.id",
            )
            .expect("诊断 SQL 失败");
        let rows: Vec<(String, String, i64, i64)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .expect("诊断查询失败")
            .flatten()
            .collect();
        for (name, url, ok, len) in rows {
            let mark = if ok == 1 { "✅" } else { "🔴" };
            println!("  {} {:<22} {} 字符", mark, name, len);
            println!("       {}", url);
        }
    }

    println!();
    println!("── 库内统计 ──");
    let conn = api_server::db_pool::get_conn();
    let total: i64 = conn
        .query_row("SELECT COUNT(*) FROM content_pool", [], |r| r.get(0))
        .unwrap_or(-1);
    println!("  content_pool 总行数: {}", total);

    let mut stmt = conn
        .prepare(
            "SELECT s.name, COUNT(p.id), \
                    SUM(CASE WHEN p.body IS NOT NULL AND p.body <> '' THEN 1 ELSE 0 END), \
                    SUM(CASE WHEN p.body_attempted_at IS NOT NULL THEN 1 ELSE 0 END) \
             FROM content_source s LEFT JOIN content_pool p ON p.source_id = s.id \
             GROUP BY s.id ORDER BY s.id",
        )
        .expect("统计 SQL 失败");
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                r.get::<_, Option<i64>>(3)?.unwrap_or(0),
            ))
        })
        .expect("统计查询失败");
    println!(
        "  {:<24} {:>6} {:>10} {:>10}",
        "源", "条数", "有全文", "已尝试抓"
    );
    for row in rows.flatten() {
        println!("  {:<24} {:>6} {:>10} {:>10}", row.0, row.1, row.2, row.3);
    }

    // 🔑 可读率 —— 白哥关心的那个数字（本轮改动的目标）
    let with_body: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM content_pool WHERE body IS NOT NULL AND body <> ''",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    println!();
    if total > 0 {
        println!(
            "  🔑 可读率: {}/{} = {:.0}%",
            with_body,
            total,
            100.0 * with_body as f64 / total as f64
        );
        println!("     （改动前实测是 16% —— 只有 feed 自带全文的 Ars 与少数 Ask HN）");
    }

    // 抽样打印一条，肉眼核对内容质量（标题/时间/摘要是不是真的）
    println!();
    println!("── 抽样 3 条（核对内容质量）──");
    let mut sample = conn
        .prepare(
            "SELECT title, published_at, category, \
                    COALESCE(score, -1), LENGTH(COALESCE(summary, '')) \
             FROM content_pool ORDER BY COALESCE(published_at, fetched_at) DESC LIMIT 3",
        )
        .expect("抽样 SQL 失败");
    let srows = sample
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        })
        .expect("抽样查询失败");
    for r in srows.flatten() {
        println!("  · [{}] {}", r.2.as_deref().unwrap_or("-"), r.0);
        println!(
            "      时间={} score={} 摘要 {} 字符",
            r.1.as_deref().unwrap_or("-"),
            if r.3 < 0 {
                "-".to_string()
            } else {
                r.3.to_string()
            },
            r.4
        );
    }

    // 幂等复跑：再抓一轮，新增应当为 0（这是本工具最值得看的一行）
    println!();
    println!("── 幂等复跑（同一批 URL 再抓一轮）──");
    let second = rt.block_on(api_server::content_fetch::fetch_all(
        &api_server::content_fetch::now_utc_iso(),
    ));
    let added: usize = second.iter().map(|o| o.inserted).sum();
    let ok2 = second.iter().filter(|o| o.error.is_none()).count();
    println!("  {}/{} 个源成功 · 新增 {} 条", ok2, second.len(), added);
    if added == 0 {
        println!("  ✅ 新增 0 条 = 幂等成立（`UNIQUE(url)` + `INSERT OR IGNORE` 生效）");
    } else {
        println!(
            "  ⚠️ 新增 {} 条 —— 源的内容在这两次之间真的有更新，或幂等键失效",
            added
        );
        println!("     （判断方法：看上面的 URL 是否重复。间隔仅几秒，正常应为 0）");
    }

    println!();
    println!("临时库留在: {}", path);
    if ok_count == 0 {
        eprintln!("🔴 全部源都失败 —— 检查网络/出口可达性（VOA/BBC 在国内不可达是已知的，但它们不在种子清单里）");
        std::process::exit(1);
    }
    println!("✅ 冒烟通过（{}/{} 个源成功）", ok_count, outcomes.len());
}
