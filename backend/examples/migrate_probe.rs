//! 迁移演练工具 —— 把**任意** `coevo.db` 跑一遍完整的 schema 初始化 + 迁移。
//!
//! # 用途：部署前拿**生产库的副本**验证迁移
//!
//! ```bash
//! cd backend
//! cp /path/to/coevo.db /tmp/coevo_copy.db          # ① 永远用副本，不碰原库
//! cargo run --example migrate_probe -- /tmp/coevo_copy.db
//! ```
//!
//! # 🔴 为什么需要它（而不是「跑测试就够了」）
//!
//! 后端测试里的迁移用例（`schema::tests::test_migrate_from_legacy_users_table`）
//! 用的是**内存库里手搭的旧结构** —— 它能验证**迁移逻辑**，但验证不了
//! 「**真实库**（带真实数据、真实索引、真实外键关系）跑起来会怎样」。
//! 这两件事不同：真实的库里可能有测试没造出来的状态（半迁移、脏数据、额外索引）。
//!
//! 🔑 尤其对**删列**这类破坏性迁移：一旦在生产上跑错，**列和数据都没了**。
//!    所以「先在一份副本上真的跑一遍，肉眼核对结果」是必要的最后一道闸。
//!
//! ⚠️ 它与 `main.rs` 的启动路径**共用同一个 `init_database`** ——
//!    不存在「演练跑的和生产跑的不是一套代码」的问题。
//!    （这正是本工具写成「调用 `db_pool::init`」而不是「自己写一遍 ALTER」的原因：
//!     自己写一遍就成了**第二份实现**，演练通过也不代表生产通过。）

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(path) = args.get(1) else {
        eprintln!("用法: cargo run --example migrate_probe -- <db-path>");
        eprintln!();
        eprintln!("⚠️ 请传**副本**路径，不要直接对生产库/本地开发库跑（本工具会改动它）");
        std::process::exit(2);
    };

    println!("── 迁移演练 ──");
    println!("目标库: {}", path);

    match api_server::db_pool::init(path) {
        Ok(()) => {
            println!("✅ 迁移完成（init_database + main.rs 的补列迁移均已执行）");
        }
        Err(e) => {
            eprintln!("🔴 迁移失败: {}", e);
            eprintln!();
            eprintln!(
                "⚠️ 若是 `no such column` / `no such table`，说明还有 SQL 引用了已不存在的列/表"
            );
            eprintln!("   （这类错误**编译期不报**，只会在这里炸出来）");
            std::process::exit(1);
        }
    }
}
