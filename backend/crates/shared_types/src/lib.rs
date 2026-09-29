//! CoEvo — Shared Types
//!
//! 跨后端 crate 共享的核心类型定义。
//!
//! # 🔴 2026-09-29 清理：只剩 `card` 一个模块
//!
//! 原 `conversation` / `growth` / `review` 三个模块、以及根上的 `CardState` 枚举**已删除** ——
//! 它们随**旧学习链**一并退役，且**0 处外部引用**（实测 `grep 'shared_types::'` 只剩 `card`）：
//!
//! | 已删 | 原属 | 为什么可以删 |
//! |---|---|---|
//! | `review.rs` | 后端 FSRS 复习（`review_log` 等表） | 学习状态整体迁**端侧** `user.db`；`card_engine` 已退役 |
//! | `growth.rs` | 后端成就引擎 | 成就改为**端侧计算**（`app/lib/services/achievement_rules.dart`） |
//! | `conversation.rs` | 对话链（`conversations` / `conversation_turns`） | 对话链整体退役 |
//! | `CardState`（根） | 后端 FSRS 卡片状态 | 端侧自实现，后端无消费者 |
//!
//! 🔑 保留 `card` 是因为它**真有消费者**：`chat_engine::concept_extractor` 用
//!    `shared_types::card::{ConceptCandidate, ExtractionResult}`。
//!
//! ⚠️ 注：`api_server` / 根 bin 的 `Cargo.toml` 里仍声明了 `shared_types` 依赖但**并未使用** ——
//!    属独立的依赖清理议题，本次未动（改依赖声明会影响 workspace 构建图）。

pub mod card;
