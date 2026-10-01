//! Simple in-memory sliding-window rate limiter
//!
//! Not production-grade — state resets on restart, no persistence.
//! Good enough for preventing casual enumeration on low-traffic admin APIs.

use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// Thread-safe global rate limiter state
struct LimiterState {
    buckets: HashMap<String, Vec<i64>>, // key → sorted timestamps (seconds)
}

fn limiter() -> &'static Mutex<LimiterState> {
    static LIMITER: OnceLock<Mutex<LimiterState>> = OnceLock::new();
    LIMITER.get_or_init(|| {
        Mutex::new(LimiterState {
            buckets: HashMap::new(),
        })
    })
}

impl LimiterState {
    /// Check and record a hit. Returns true if allowed, false if rate exceeded.
    fn check(&mut self, key: &str, max_hits: usize, window_secs: i64) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let cutoff = now - window_secs;

        let hits = self.buckets.entry(key.to_string()).or_default();

        // Remove expired entries
        hits.retain(|&t| t > cutoff);

        if hits.len() >= max_hits {
            false // rate limited
        } else {
            hits.push(now);
            true
        }
    }
}

/// Extract client IP from headers (X-Forwarded-For first, then X-Real-IP, fallback "unknown")
fn client_ip(headers: &HeaderMap) -> String {
    if let Some(v) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        return v.split(',').next().unwrap_or("unknown").trim().to_string();
    }
    if let Some(v) = headers.get("x-real-ip").and_then(|v| v.to_str().ok()) {
        return v.to_string();
    }
    "unknown".to_string()
}

/// Check if this request is within rate limits.
/// Returns `Ok(())` if allowed, `Err(response)` if rate limited.
pub fn check_rate_limit(
    headers: &HeaderMap,
    max_hits: usize,
    window_secs: i64,
) -> Result<(), axum::response::Response> {
    let ip = client_ip(headers);
    let mut state = limiter().lock().unwrap();
    if state.check(&ip, max_hits, window_secs) {
        Ok(())
    } else {
        Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({"error": "rate_limited", "retry_after_secs": window_secs})),
        )
            .into_response())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rate_limiter_allows_within_limit() {
        let mut state = LimiterState {
            buckets: HashMap::new(),
        };
        assert!(state.check("127.0.0.1", 5, 60));
        assert!(state.check("127.0.0.1", 5, 60));
        assert!(state.check("127.0.0.1", 5, 60));
    }

    #[test]
    fn test_rate_limiter_blocks_excess() {
        let mut state = LimiterState {
            buckets: HashMap::new(),
        };
        for _ in 0..5 {
            assert!(state.check("192.168.1.1", 5, 60));
        }
        assert!(!state.check("192.168.1.1", 5, 60)); // 6th hit blocked
    }

    #[test]
    fn test_rate_limiter_per_ip_independent() {
        let mut state = LimiterState {
            buckets: HashMap::new(),
        };
        for _ in 0..5 {
            assert!(state.check("10.0.0.1", 5, 60));
        }
        // Different IP should still be allowed
        assert!(state.check("10.0.0.2", 5, 60));
    }
}
