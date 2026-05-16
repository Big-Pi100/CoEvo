//! FSRS-5 algorithm implementation — minimal self-contained scheduling.
//!
//! Uses the well-known default parameters from the FSRS paper.
//! Avoids the `fsrs` crate dependency conflict with rusqlite(bundled).

/// FSRS-5 default parameters (w0..w16).
/// Source: open-spaced-repetition/fsrs-rs DEFAULT_PARAMETERS
const W: [f64; 17] = [
    0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01,
    1.49, 0.14, 0.94, 2.18, 0.05, 0.34, 1.26, 0.29, 2.61,
];

/// FSRS rating (maps to user's subjective judgement):
/// 1 = Again (forgot)
/// 2 = Hard (recalled with difficulty)
/// 3 = Good (recalled correctly)
/// 4 = Easy (recalled effortlessly)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rating {
    Again = 1,
    Hard = 2,
    Good = 3,
    Easy = 4,
}

/// Convert from our existing rating schema (pass/fail → 3/1)
impl Rating {
    pub fn from_pass(passed: bool, is_easy: bool) -> Self {
        match (passed, is_easy) {
            (true, true) => Rating::Easy,
            (true, false) => Rating::Good,
            (false, _) => Rating::Again,
        }
    }
}

/// Card memory state (matches card_memory table columns)
#[derive(Debug, Clone)]
pub struct FsrsMemory {
    pub difficulty: f64,  // D
    pub stability: f64,   // S (in days)
    pub reps: i32,
    pub lapses: i32,
    pub last_review: Option<i64>,
}

impl Default for FsrsMemory {
    fn default() -> Self {
        FsrsMemory {
            difficulty: 0.0,   // initialized to 0 = unset, will be set on first review
            stability: 0.0,
            reps: 0,
            lapses: 0,
            last_review: None,
        }
    }
}

/// Scheduling result: (next_stability_in_days, next_difficulty)
#[derive(Debug)]
pub struct ScheduleResult {
    pub stability: f64,
    pub difficulty: f64,
    pub interval_seconds: i64,
}

/// Run FSRS-5 scheduling for a card given a rating.
///
/// `elapsed_days`: days since last review (0 if first review or same-day)
/// `mem`: current card memory state from DB
pub fn schedule(mem: &FsrsMemory, rating: Rating, elapsed_days: f64) -> ScheduleResult {
    let r = rating as i32 as f64;

    let difficulty = if mem.reps == 0 {
        // First review: initialize difficulty
        init_difficulty(r)
    } else {
        // Subsequent: update difficulty
        next_difficulty(mem.difficulty, r)
    };

    let stability = if mem.reps == 0 {
        // First review stability
        first_stability(r)
    } else if rating == Rating::Again {
        // Forgot → stability after failure
        stability_after_failure(mem.difficulty, mem.stability, elapsed_days)
    } else {
        // Remembered → stability after success
        stability_after_success(mem.difficulty, mem.stability, r, elapsed_days)
    };

    // Clamp to reasonable bounds
    let difficulty = difficulty.clamp(1.0, 10.0);
    let stability = stability.max(0.01); // min ~9 seconds

    let interval_seconds = (stability * 86400.0) as i64;

    ScheduleResult {
        stability,
        difficulty,
        interval_seconds,
    }
}

// ── FSRS core formulas ──

fn init_difficulty(r: f64) -> f64 {
    W[4] - W[5] * (r - 3.0)
}

fn next_difficulty(d: f64, r: f64) -> f64 {
    let delta = W[6] * (r - 3.0);
    d - delta
}

fn first_stability(r: f64) -> f64 {
    let base = match r as i32 {
        1 => W[0],
        2 => W[1],
        3 => W[2],
        4 => W[3],
        _ => W[2],
    };
    base.max(0.01)
}

fn stability_after_success(d: f64, s: f64, r: f64, elapsed: f64) -> f64 {
    let hard_penalty = if r == 2.0 { W[15] } else { 1.0 };
    let easy_bonus = if r == 4.0 { W[16] } else { 1.0 };

    s * (1.0 + (W[8]).exp() * (11.0 - d) * s.powf(-W[9])
        * (((W[10]) * (1.0 - r / 4.0)).exp() - 1.0))
        * hard_penalty
        * easy_bonus
}

fn stability_after_failure(d: f64, s: f64, elapsed: f64) -> f64 {
    (W[11] * d.powf(-W[12]) * ((s + 1.0).powf(W[13]) - 1.0)
        * ((W[14]) * (1.0 - d / 10.0)).exp())
        .max(0.01)
}
