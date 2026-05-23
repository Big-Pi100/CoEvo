//! K12 横向覆盖测试：科目定义 + 生命周期日志 + 并行跑步器
//!
//! 5 学段 × 适用科目 = ~30 个测试用例
//! 每用例独立 DB + 完整生命周期日志

mod subjects;
mod lifecycle_log;

pub use subjects::*;
pub use lifecycle_log::*;
