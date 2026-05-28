//! API Server — Axum 路由 + WS + 中间件
//!
//! 复用 LinguaFlow: auth.rs, auth_middleware.rs, db_pool.rs

pub mod admin_handlers;
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
pub mod curriculum_loader;
pub mod k12_quiz;
pub mod k12_quiz_api;
pub mod k12_quiz_loader;
pub mod reading_loader;
pub mod ws;
