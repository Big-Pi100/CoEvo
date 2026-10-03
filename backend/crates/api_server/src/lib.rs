//! API Server — Axum 路由 + 中间件
//!
//! 复用 LinguaFlow: auth.rs, auth_middleware.rs, db_pool.rs
//!
//! # 🔴 2026-09-29：旧学习链已退役
//! 学习状态整体迁到端侧（`user.db`：`card_review_state` / `review_log` / `user_word` / `bookmark`），
//! 后端随之退役以下模块（原依赖的表已从 `coevo.db` 删除）：
//!
//! | 已退役模块 | 原依赖的表 | 原因 |
//! |---|---|---|
//! | `ws`（WebSocket chat） | `conversations` · `user_cards` · `card_memory` | app 内 `/chat` **无 UI 入口** |
//! | `plan_handler`（K12 计划 XML） | `conversations` · `user_plan_progress` | K12 体系整体清退 |
//! | `review_handler`（status/defer） | `defer_queue` · `card_memory` | 只被 chat 链调用 |
//! | `curriculum_admin` / `curriculum_loader` | `card_relations` · `prebuilt_*` | K12 后台 |
//! | `debug_logger` / `debug_trackers_cache` | `debug_logs` · `debug_trackers` | 只服务 admin 调试面板 |
//! | `achievement_engine`（+ crate `growth_engine`） | `user_cards` · `review_log` · `achievements` | 成就方向定为「**端侧计算**」 |
//!
//! crate `card_engine`（后端 FSRS 调度）同时退役 —— 端侧已自行实现 FSRS。

#![allow(clippy::result_large_err)]
#![allow(clippy::too_many_arguments)]
#![allow(clippy::type_complexity)]
#![allow(dead_code)]
#![allow(clippy::incompatible_msrv)]
#![allow(clippy::if_same_then_else)]
#![allow(clippy::unnecessary_to_owned)]

pub mod admin_handlers;
pub mod app_config_cache;
pub mod auth;
pub mod auth_middleware;
pub mod campaign_executor;
pub mod campaign_handler;
pub mod campaign_member_handler;
pub mod campaign_scheduler;
/// 内容合规闸门（在线制卡的**前置**检查 · 涉主权/涉政/涉黄暴/涉歧视）
pub mod compliance;
pub mod config_admin;
pub mod content_extract;
pub mod content_fetch;
pub mod content_handler;
pub mod content_quality;
pub mod content_rss;
pub mod db_pool;
pub mod distribution_handler;
pub mod encryption;
pub mod error;
pub mod h5_template;
pub mod llm;
/// 词库在线制卡（LLM 兜底 · 服务端全局缓存）
pub mod llm_card;
pub mod llm_poster;
pub mod pay_handlers;
pub mod plans_handlers;
pub mod poster_template;
pub mod rate_limiter;
pub mod referral_handler;
pub mod routes;
pub mod schema;
pub mod share_data;
pub mod subject_router;
pub mod subscription;
pub mod tencent_asr;
pub mod tencent_tts;
pub mod test_helpers;
pub mod trial_handler;
pub mod wechat_pay;
