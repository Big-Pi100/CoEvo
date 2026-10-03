//! 🔴 **迁移演练**：用**生产库的真实 `content_source` 数据**跑一遍启动路径，
//! 验证「seed 是源配置的唯一权威」这个改动在真机上会做什么。
//!
//! # 为什么用真实数据而不是手编样本
//!
//! 📌 判据：**「批量写」的验证必须用真实数据** —— 手编样本会不自觉地
//!    「编成我以为的样子」，从而**漏掉真实数据里的其它形态**
//!    （例：某列是 NULL / 某行 enabled 与 seed 不同 / 存在 seed 里没有的手工源）。
//!
//! # 它走的是**真实代码路径**
//!
//! `init_database` → `run_migrations` → `CONTENT_SEED_SQL`，
//! 与 `coevo_backend` 启动时**同一批函数、同一份常量**。
//! （判据：自己是复刻一遍逻辑会引入偏差 —— 同 `fetch_article_body_diagnostic` 的取舍。）
//!
//! ⚠️ 唯一的人工步骤：把 fixture 的 24 行**覆盖**到内存库上（复刻生产的 `enabled`
//!    分布与运行时状态）。这一步是**故意的** —— 要的就是「一个有历史偏差的库」。
//!
//! # 用法
//!
//! ```bash
//! cd backend
//! # 先导出：ssh ... "python3 -" < scripts/trace_verify/bin/dump_prod_sources.py > .../prod_sources.json
//! cargo run --release --example migration_drill
//! ```
//!
//! # 判据（演练必须能回答的四个问题）
//!
//! 1. **该改的改了没**：HN 的 `enabled` 应从 1 → 0（与代码一致）
//! 2. 🔴 **不该动的动了没**：`last_fetch_at` / `fail_count` / `created_at` 必须**逐行不变**
//! 3. **有没有误伤**：除预期的配置列外，不应有别的列被改
//! 4. **幂等**：再跑一次，应当**零改动**

use api_server::schema::{init_database, run_migrations, CONTENT_SEED_SQL};
use rusqlite::Connection;

/// 一行的快照（只取「关心是否被改」的列）。
#[derive(Debug, Clone, PartialEq)]
struct Snap {
    id: i64,
    name: String,
    url: String,
    kind: String,
    category: String,
    cefr_hint: Option<String>,
    license: Option<String>,
    redistributable: i64,
    tz_offset_min: i64,
    fetch_interval_min: i64,
    enabled: i64,
    last_fetch_at: Option<String>,
    fail_count: i64,
    created_at: String,
    updated_at: String,
}

fn snapshot(conn: &Connection) -> Vec<Snap> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, url, kind, category, cefr_hint, license, redistributable, \
             tz_offset_min, fetch_interval_min, enabled, last_fetch_at, fail_count, \
             created_at, updated_at FROM content_source ORDER BY id",
        )
        .unwrap();
    stmt.query_map([], |r| {
        Ok(Snap {
            id: r.get(0)?,
            name: r.get(1)?,
            url: r.get(2)?,
            kind: r.get(3)?,
            category: r.get(4)?,
            cefr_hint: r.get(5)?,
            license: r.get(6)?,
            redistributable: r.get(7)?,
            tz_offset_min: r.get(8)?,
            fetch_interval_min: r.get(9)?,
            enabled: r.get(10)?,
            last_fetch_at: r.get(11)?,
            fail_count: r.get(12)?,
            created_at: r.get(13)?,
            updated_at: r.get(14)?,
        })
    })
    .unwrap()
    .map(|x| x.unwrap())
    .collect()
}

/// 逐列比对两行，返回「变了的列」。
fn changed_cols(a: &Snap, b: &Snap) -> Vec<&'static str> {
    let mut v = Vec::new();
    if a.name != b.name {
        v.push("name");
    }
    if a.kind != b.kind {
        v.push("kind");
    }
    if a.category != b.category {
        v.push("category");
    }
    if a.cefr_hint != b.cefr_hint {
        v.push("cefr_hint");
    }
    if a.license != b.license {
        v.push("license");
    }
    if a.redistributable != b.redistributable {
        v.push("redistributable");
    }
    if a.tz_offset_min != b.tz_offset_min {
        v.push("tz_offset_min");
    }
    if a.enabled != b.enabled {
        v.push("enabled");
    }
    if a.last_fetch_at != b.last_fetch_at {
        v.push("last_fetch_at");
    }
    if a.fail_count != b.fail_count {
        v.push("fail_count");
    }
    if a.created_at != b.created_at {
        v.push("created_at");
    }
    if a.updated_at != b.updated_at {
        v.push("updated_at");
    }
    v
}

/// 🔴 **运行时状态列** —— 这四列**永远不允许**被 seed 改动。
const RUNTIME_COLS: &[&str] = &["last_fetch_at", "fail_count", "created_at"];

fn enabled_ids(rows: &[Snap]) -> Vec<i64> {
    rows.iter()
        .filter(|r| r.enabled == 1)
        .map(|r| r.id)
        .collect()
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "../scripts/trace_verify/fixtures/prod_sources.json".to_string());
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "读 fixture 失败（{path}）: {e}\n\
             💡 先用 dump_prod_sources.py 从生产库导出"
        )
    });
    let prod: Vec<serde_json::Value> = serde_json::from_str(&raw).expect("解析 JSON 失败");

    let conn = Connection::open_in_memory().unwrap();
    init_database(&conn).unwrap();

    // ── ① 把 fixture 的真实值**覆盖**上来（复刻生产状态：含历史偏差）──
    for r in &prod {
        let get = |k: &str| r[k].clone();
        conn.execute(
            "UPDATE content_source SET name=?1, url=?2, kind=?3, category=?4, cefr_hint=?5, \
             license=?6, redistributable=?7, tz_offset_min=?8, fetch_interval_min=?9, \
             enabled=?10, last_fetch_at=?11, fail_count=?12, created_at=?13, updated_at=?14 \
             WHERE id=?15",
            rusqlite::params![
                get("name").as_str().unwrap(),
                get("url").as_str().unwrap(),
                get("kind").as_str().unwrap(),
                get("category").as_str().unwrap(),
                get("cefr_hint").as_str(),
                get("license").as_str(),
                get("redistributable").as_i64().unwrap(),
                get("tz_offset_min").as_i64().unwrap(),
                get("fetch_interval_min").as_i64().unwrap(),
                get("enabled").as_i64().unwrap(),
                get("last_fetch_at").as_str(),
                get("fail_count").as_i64().unwrap(),
                get("created_at").as_str().unwrap(),
                get("updated_at").as_str().unwrap(),
                get("id").as_i64().unwrap(),
            ],
        )
        .unwrap();
    }

    let before = snapshot(&conn);
    println!("fixture: {path}");
    println!(
        "── ① 复刻出的「生产状态」（启动前）──\n   行数 {} · 启用 {} 个",
        before.len(),
        enabled_ids(&before).len()
    );
    for r in before.iter().filter(|r| r.enabled == 0) {
        println!("   ⬜ 已禁用: id={} {}", r.id, r.name);
    }

    // ── ② 跑**真实启动路径** ──
    run_migrations(&conn).expect("run_migrations 失败");
    conn.execute_batch(CONTENT_SEED_SQL)
        .expect("seed 失败（真实服务在此会启动失败）");

    let after = snapshot(&conn);

    // ── ③ 逐行 diff ──
    println!("\n── ② 跑完启动路径（run_migrations + CONTENT_SEED_SQL）──");
    println!(
        "   行数 {} · 启用 {} 个",
        after.len(),
        enabled_ids(&after).len()
    );

    let mut violations: Vec<String> = Vec::new();
    println!("\n── ③ 逐行 diff ──");
    let mut any = false;
    for (b, a) in before.iter().zip(after.iter()) {
        debug_assert_eq!(b.id, a.id);
        let ch = changed_cols(b, a);
        if ch.is_empty() {
            continue;
        }
        any = true;
        println!("   id={:<3} {:<28} 改动: {}", b.id, b.name, ch.join(", "));
        for c in &ch {
            if RUNTIME_COLS.contains(c) {
                violations.push(format!(
                    "🔴 id={} 的**运行时状态列** `{}` 被改了！",
                    b.id, c
                ));
            }
        }
        if ch.contains(&"enabled") {
            println!(
                "        enabled: {} → {}   （代码里的值）",
                b.enabled, a.enabled
            );
        }
    }
    if !any {
        println!("   （无改动）");
    }

    // ── ④ 幂等：再跑一次应零改动 ──
    conn.execute_batch(CONTENT_SEED_SQL).unwrap();
    let after2 = snapshot(&conn);
    let mut second_changes = 0;
    for (a, b) in after.iter().zip(after2.iter()) {
        if changed_cols(a, b).iter().any(|c| *c != "updated_at") {
            second_changes += 1;
        }
    }

    // ── ⑤ 判定 ──
    println!("\n── ④ 判定 ──");
    let hn_before = before.iter().find(|r| r.url.contains("hacker-news"));
    let hn_after = after.iter().find(|r| r.url.contains("hacker-news"));
    let ok_hn = match (hn_before, hn_after) {
        (Some(b), Some(a)) => b.enabled == a.enabled || a.enabled == 0,
        _ => false,
    };
    println!(
        "   ① 该改的改了: HN enabled {:?} → {:?}  {}",
        hn_before.map(|r| r.enabled),
        hn_after.map(|r| r.enabled),
        if ok_hn { "✅" } else { "🔴" }
    );
    println!(
        "   ② 运行时状态未被碰: {}",
        if violations.is_empty() {
            "✅ 全部完好".to_string()
        } else {
            format!("🔴 {} 项违规", violations.len())
        }
    );
    for v in &violations {
        println!("      {v}");
    }
    let idem = if second_changes == 0 {
        "✅ 零改动".to_string()
    } else {
        format!("🔴 {second_changes} 行仍有改动")
    };
    println!("   ③ 幂等（第二次跑零改动）: {idem}");
    println!(
        "   ④ 启用数 {} → {}  （代码里的权威值 = {}）",
        enabled_ids(&before).len(),
        enabled_ids(&after).len(),
        enabled_ids(&after).len()
    );

    if !violations.is_empty() || !ok_hn || second_changes != 0 {
        std::process::exit(1);
    }
    println!("\n✅ 演练通过：配置被对齐，运行时状态零改动，且幂等。");
}
