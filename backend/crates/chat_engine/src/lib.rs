//! Chat Engine — N1 AI对话 + N2 概念提取
//!
//! 复用 LinguaFlow: llm_caller.rs, concept_extractor.rs, prompt_builder.rs

#![allow(clippy::empty_line_after_doc_comments)]
#![allow(clippy::doc_overindented_list_items)]

pub mod concept_extractor;
pub mod config;
pub mod llm_caller;
pub mod pipeline_router;
pub mod prompt_loader;
pub mod word_bank;
