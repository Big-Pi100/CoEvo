//! AES-256-GCM encryption for PII fields
//!
//! ## Key
//! Reads `COEVO_PII_KEY` env var (64 hex chars = 32 bytes).
//! Falls back to a hardcoded dev key with a warning if not set.
//!
//! ## Storage format
//! `base64(nonce_12bytes || ciphertext_with_tag)`
//! where `ciphertext_with_tag` = output of Aes256Gcm::encrypt
//! (plaintext + 16-byte GCM authentication tag)
//!
//! ## Search
//! AES-GCM is non-deterministic (random nonce per encryption),
//! so direct SQL WHERE matching is impossible.
//! For bind-lookup, we use `bind_hash = SHA-256(real_name + phone)` (hex).

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::Engine;
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

/// The AES-256 key (32 bytes). Initialized once on first use.
fn get_key() -> &'static [u8; 32] {
    static KEY: OnceLock<[u8; 32]> = OnceLock::new();
    KEY.get_or_init(|| {
        let env_val = std::env::var("COEVO_PII_KEY").unwrap_or_default();
        if env_val.len() == 64 {
            let mut key = [0u8; 32];
            hex::decode_to_slice(&env_val, &mut key).expect("COEVO_PII_KEY must be 64 hex chars");
            key
        } else {
            tracing::warn!(
                "COEVO_PII_KEY not set or invalid (got {} chars, expected 64). Using DEV key — DO NOT USE IN PRODUCTION",
                env_val.len()
            );
            // dev-only deterministic key: 64x '0'
            let mut key = [0u8; 32];
            hex::decode_to_slice("0".repeat(64), &mut key).unwrap();
            key
        }
    })
}

/// AES-256-GCM encrypt a plaintext string.
/// Returns base64(nonce(12) || ciphertext_with_tag).
pub fn encrypt(plaintext: &str) -> String {
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(get_key());
    let cipher = Aes256Gcm::new(key);

    // Generate random 12-byte nonce
    let mut nonce_bytes = [0u8; 12];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .expect("AES-256-GCM encryption should not fail");

    // Encode as base64(nonce || ciphertext_with_tag)
    let mut combined = Vec::with_capacity(12 + ciphertext.len());
    combined.extend_from_slice(&nonce_bytes);
    combined.extend_from_slice(&ciphertext);
    base64::engine::general_purpose::STANDARD.encode(&combined)
}

/// AES-256-GCM decrypt a string previously encrypted with `encrypt()`.
/// Returns the original plaintext, or empty string on failure.
pub fn decrypt(encoded: &str) -> String {
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(get_key());
    let cipher = Aes256Gcm::new(key);

    let combined = match base64::engine::general_purpose::STANDARD.decode(encoded) {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("AES decrypt: base64 decode failed: {}", e);
            return String::new();
        }
    };

    if combined.len() < 12 {
        tracing::error!("AES decrypt: encoded data too short ({})", combined.len());
        return String::new();
    }

    let (nonce_bytes, ciphertext) = combined.split_at(12);
    let nonce = Nonce::from_slice(nonce_bytes);

    match cipher.decrypt(nonce, ciphertext) {
        Ok(plaintext) => String::from_utf8(plaintext).unwrap_or_default(),
        Err(e) => {
            tracing::error!("AES decrypt: decryption failed (wrong key?): {}", e);
            String::new()
        }
    }
}

/// Compute a deterministic search hash: SHA-256(real_name + phone) → hex
pub fn bind_hash(real_name: &str, phone: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(real_name.as_bytes());
    hasher.update(phone.as_bytes());
    hex::encode(hasher.finalize())
}

/// Compute SHA-256 hex digest of a single input (e.g., phone number for login lookup)
pub fn sha256_hash(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// Check if a string looks like encrypted data (base64 of 12+ bytes = 16+ chars base64)
pub fn is_encrypted(s: &str) -> bool {
    s.len() >= 16 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let original = "张三";
        let encrypted = encrypt(original);
        assert_ne!(encrypted, original);
        assert!(encrypted.len() > 20);
        let decrypted = decrypt(&encrypted);
        assert_eq!(decrypted, original);
    }

    #[test]
    fn test_encrypt_different_each_time() {
        let original = "13800138000";
        let e1 = encrypt(original);
        let e2 = encrypt(original);
        // AES-GCM with random nonce should produce different ciphertext each time
        assert_ne!(e1, e2);
        // Both should decrypt correctly
        assert_eq!(decrypt(&e1), original);
        assert_eq!(decrypt(&e2), original);
    }

    #[test]
    fn test_bind_hash_consistent() {
        let h1 = bind_hash("张三", "13800138000");
        let h2 = bind_hash("张三", "13800138000");
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 64); // SHA-256 hex = 64 chars
    }

    #[test]
    fn test_bind_hash_different() {
        let h1 = bind_hash("张三", "13800138000");
        let h2 = bind_hash("李四", "13900139000");
        assert_ne!(h1, h2);
    }

    #[test]
    fn test_decrypt_empty_on_garbage() {
        assert_eq!(decrypt("not-base64!!!"), "");
        assert_eq!(decrypt("AA"), ""); // too short after decode
    }

    #[test]
    fn test_is_encrypted() {
        let enc = encrypt("test");
        assert!(is_encrypted(&enc));
        assert!(!is_encrypted("hello"));
        assert!(!is_encrypted(""));
    }
}
