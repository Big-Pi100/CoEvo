//! CoEvo — Shared Types
//!
//! Core type definitions shared across all backend crates.

pub mod card;
pub mod review;
pub mod growth;
pub mod conversation;

// ── Card States (FSRS) ──

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum CardState {
    New = 0,
    Learning = 1,
    Review = 2,
    Relearning = 3,
}

impl CardState {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => CardState::New,
            1 => CardState::Learning,
            2 => CardState::Review,
            3 => CardState::Relearning,
            _ => CardState::New,
        }
    }

    pub fn to_i32(&self) -> i32 {
        *self as i32
    }
}
