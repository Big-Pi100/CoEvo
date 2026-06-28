//! API Server — Axum 路由 + WS + 中间件
//!
//! 复用 LinguaFlow: auth.rs, auth_middleware.rs, db_pool.rs

#![allow(clippy::result_large_err)]
#![allow(clippy::too_many_arguments)]
#![allow(clippy::type_complexity)]
#![allow(dead_code)]
#![allow(clippy::incompatible_msrv)]
#![allow(clippy::if_same_then_else)]
#![allow(clippy::unnecessary_to_owned)]

pub mod admin_handlers;
pub mod achievement_engine;
pub mod auth;
pub mod auth_middleware;
pub mod db_pool;
pub mod e2e_runner;
pub mod encryption;
pub mod error;
pub mod llm;
pub mod plan_handler;
pub mod rate_limiter;
pub mod routes;
pub mod schema;
pub mod subject_router;
pub mod tencent_asr;
pub mod tencent_tts;
pub mod test_helpers;
pub mod app_config_cache;
pub mod config_admin;
pub mod curriculum_admin;
pub mod curriculum_loader;
pub mod debug_logger;
pub mod subscription;
pub mod wechat_pay;
pub mod pay_handlers;
pub mod plans_handlers;
pub mod debug_trackers_cache;
pub mod k12_quiz;
pub mod k12_quiz_api;
pub mod k12_quiz_loader;
pub mod ws;
pub mod referral_handler;
pub mod campaign_handler;
pub mod campaign_member_handler;
pub mod trial_handler;
pub mod distribution_handler;
pub mod campaign_scheduler;
pub mod campaign_executor;
pub mod llm_poster;
pub mod poster_template;
pub mod h5_template;
pub mod share_data;
